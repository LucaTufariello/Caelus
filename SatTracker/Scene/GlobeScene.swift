//
//  GlobeScene.swift
//  SatTracker
//
//  Scene assembly, the orbit camera, and the Sun.
//
//  Threading: input arrives on the main thread and writes only the rig's
//  *target* pose under a lock. The render thread reads that target once per
//  frame, eases the *current* pose toward it, and writes the camera node's
//  transform. Nothing else touches the camera, so there is no contention and no
//  frame-rate dependence in the feel of the drag.
//

import AppKit
import os
import SceneKit
import simd

@MainActor
final class GlobeScene {

    // MARK: - Camera constants

    /// Vertical field of view, degrees. Also the basis for drag sensitivity.
    static let fieldOfView: CGFloat = 34

    let scene = SCNScene()
    let cameraNode = SCNNode()
    let rig: CameraRig

    let earth: SCNNode
    let satellites: SatelliteLayer
    let orbits = OrbitTrackLayer()
    let observer = ObserverMarker()

    private let camera = SCNCamera()
    private let sunNode = SCNNode()
    private let sunLight = SCNLight()

    // MARK: - Lifecycle

    init(renderIndices: [SatelliteGroup: [Int]], screenScale: CGFloat) {
        earth = EarthNode.make()
        satellites = SatelliteLayer(renderIndices: renderIndices,
                                    baseRadius: 2.2,
                                    screenScale: screenScale)

        // Camera.
        camera.fieldOfView = Self.fieldOfView
        camera.zNear = 0.005
        camera.zFar = 400
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.bloomIntensity = 0.45
        camera.bloomThreshold = 0.92
        camera.bloomBlurRadius = 14
        camera.vignettingIntensity = 0.35
        camera.vignettingPower = 2.4
        cameraNode.camera = camera
        cameraNode.name = "camera"
        scene.rootNode.addChildNode(cameraNode)

        rig = CameraRig(cameraNode: cameraNode,
                        pose: CameraRig.Pose(latitude: 22, longitude: 8, distance: 3.5))

        // Lights.
        sunLight.type = .directional
        sunLight.intensity = 1_150
        sunLight.color = NSColor(srgbRed: 1.0, green: 0.975, blue: 0.94, alpha: 1)
        sunLight.castsShadow = false
        sunNode.light = sunLight
        sunNode.name = "sun"
        scene.rootNode.addChildNode(sunNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 55
        ambient.color = NSColor(srgbRed: 0.42, green: 0.52, blue: 0.70, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // Content.
        scene.background.contents = NSColor(srgbRed: 0.012, green: 0.020, blue: 0.039, alpha: 1)
        scene.rootNode.addChildNode(StarField.make())
        scene.rootNode.addChildNode(earth)
        for layer in satellites.layers.values {
            scene.rootNode.addChildNode(layer.node)
        }
        scene.rootNode.addChildNode(orbits.root)
        scene.rootNode.addChildNode(observer.root)

        updateSun(SIMD3<Float>(1, 0, 0))
    }

    // MARK: - Sun

    /// `direction` points from the Earth toward the Sun, in scene space.
    func updateSun(_ direction: SIMD3<Float>) {
        let d = simd_normalize(direction)
        sunNode.simdPosition = d * 6
        sunNode.simdOrientation = CameraRig.orientation(forward: -d, up: SIMD3<Float>(0, 1, 0))
        EarthNode.updateSun(direction: d, earth: earth)
    }

    // MARK: - Visibility

    func setVisible(_ group: SatelliteGroup, _ visible: Bool) {
        satellites.setVisible(group, visible)
    }

    func setObserverVisible(_ visible: Bool) {
        observer.setVisible(visible)
    }

    // MARK: - Interaction

    func orbit(dx: CGFloat, dy: CGFloat, viewportHeight: CGFloat) {
        let degreesPerPixel = rig.degreesPerPixel(viewportHeight: viewportHeight,
                                                  fieldOfView: Self.fieldOfView)
        rig.orbit(dx: Float(dx), dy: Float(dy), degreesPerPixel: degreesPerPixel)
    }

    func zoom(by factor: CGFloat) {
        rig.zoom(by: Float(factor))
    }

    /// Ease the camera to look straight down on a coordinate.
    func focus(latitude: Double, longitude: Double, distance: Float? = nil) {
        rig.focus(latitude: Float(latitude),
                  longitude: Float(longitude),
                  distance: distance)
    }

    /// Return to the opening view.
    func resetCamera() {
        rig.focus(latitude: 22, longitude: 8, distance: 3.5)
    }

    var distance: Float { rig.currentDistance() }
}

// MARK: - Camera rig

/// A north-up orbit camera with critically damped easing.
///
/// The pose is expressed as the sub-camera point on the globe plus a distance,
/// which makes "fly to this coordinate" a single assignment and keeps the
/// horizon level at every latitude.
final class CameraRig: @unchecked Sendable {

    struct Pose: Equatable {
        /// Degrees, −89…89.
        var latitude: Float
        /// Degrees, any value; normalised on use.
        var longitude: Float
        /// Scene units from the centre.
        var distance: Float
    }

    private struct State {
        var target: Pose
        var current: Pose
    }

    static let minDistance: Float = 1.055
    static let maxDistance: Float = 14
    static let latitudeLimit: Float = 89

    /// How quickly the camera catches its target, per second.
    private static let easingRate: Float = 13

    private let lock: OSAllocatedUnfairLock<State>
    private weak var cameraNode: SCNNode?

    init(cameraNode: SCNNode, pose: Pose) {
        self.cameraNode = cameraNode
        let clamped = Pose(latitude: min(Self.latitudeLimit, max(-Self.latitudeLimit, pose.latitude)),
                           longitude: pose.longitude,
                           distance: min(Self.maxDistance, max(Self.minDistance, pose.distance)))
        lock = OSAllocatedUnfairLock(initialState: State(target: clamped, current: clamped))
        apply(clamped, to: cameraNode)
    }

    // MARK: - Input (main thread)

    /// Rotation in degrees per pixel at the current distance.
    ///
    /// Derived from the projection so the surface tracks the cursor: one pixel
    /// subtends `fov / height` of view angle, and the surface sits roughly
    /// `distance − 1` in front of the camera.
    func degreesPerPixel(viewportHeight: CGFloat, fieldOfView: CGFloat) -> Float {
        let d = currentDistance()
        let height = max(200, Float(viewportHeight))
        let perPixel = (max(0.05, d - 1)) * Float(fieldOfView) / height
        return min(1.6, max(0.005, perPixel))
    }

    /// `dx` and `dy` are in points, `dy` positive upwards.
    func orbit(dx: Float, dy: Float, degreesPerPixel: Float) {
        lock.withLock { state in
            // Drag the globe: content follows the cursor, so the camera moves
            // the opposite way on both axes.
            state.target.longitude -= dx * degreesPerPixel
            state.target.latitude = min(Self.latitudeLimit,
                                        max(-Self.latitudeLimit,
                                            state.target.latitude - dy * degreesPerPixel))
        }
    }

    func zoom(by factor: Float) {
        lock.withLock { state in
            state.target.distance = min(Self.maxDistance,
                                        max(Self.minDistance, state.target.distance * factor))
        }
    }

    func focus(latitude: Float, longitude: Float, distance: Float? = nil) {
        lock.withLock { state in
            state.target.latitude = min(Self.latitudeLimit, max(-Self.latitudeLimit, latitude))
            // Take the short way round from where we are now.
            state.target.longitude = Self.nearest(state.target.longitude, to: longitude)
            if let distance {
                state.target.distance = min(Self.maxDistance, max(Self.minDistance, distance))
            }
        }
    }

    // MARK: - Render thread

    func step(dt: Float) {
        guard let cameraNode else { return }
        let pose = lock.withLock { state -> Pose in
            let a = 1 - exp(-Self.easingRate * max(0, min(0.25, dt)))
            state.current.distance += (state.target.distance - state.current.distance) * a
            state.current.latitude += (state.target.latitude - state.current.latitude) * a
            let delta = Self.shortestDelta(from: state.current.longitude,
                                           to: state.target.longitude)
            state.current.longitude += delta * a
            if abs(state.target.longitude - state.current.longitude) < 0.001 {
                state.current.longitude = state.target.longitude
            }
            return state.current
        }
        apply(pose, to: cameraNode)
    }

    func currentDistance() -> Float {
        lock.withLock { $0.current.distance }
    }

    func currentPose() -> Pose {
        lock.withLock { $0.current }
    }

    // MARK: - Maths

    private func apply(_ pose: Pose, to node: SCNNode) {
        let direction = GeoMath.unitVector(lat: Double(pose.latitude), lon: Double(pose.longitude))
        node.simdPosition = direction * pose.distance
        node.simdOrientation = Self.orientation(forward: -direction, up: SIMD3<Float>(0, 1, 0))
    }

    /// Rotation whose local −Z is `forward` and whose local +Y is as close to
    /// `up` as possible.
    static func orientation(forward: SIMD3<Float>, up: SIMD3<Float>) -> simd_quatf {
        var f = forward
        if simd_length(f) < 1e-6 { f = SIMD3<Float>(0, 0, -1) }
        f = simd_normalize(f)

        var u = up
        if simd_length(u) < 1e-6 { u = SIMD3<Float>(0, 1, 0) }
        u = simd_normalize(u)
        if abs(simd_dot(f, u)) > 0.999 {
            u = abs(f.y) > 0.9 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
            if abs(simd_dot(f, u)) > 0.999 { u = SIMD3<Float>(1, 0, 0) }
        }

        let right = simd_normalize(simd_cross(f, u))
        let trueUp = simd_cross(right, f)
        return simd_quatf(simd_float3x3(right, trueUp, -f))
    }

    private static func shortestDelta(from: Float, to: Float) -> Float {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    /// The representation of `longitude` closest to `reference`.
    private static func nearest(_ reference: Float, to longitude: Float) -> Float {
        reference + shortestDelta(from: reference, to: longitude)
    }
}

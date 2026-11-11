//
//  GlobeView.swift
//  SatTracker
//
//  The SwiftUI ↔ SceneKit bridge.
//
//  The render delegate runs on SceneKit's render thread: it advances the camera
//  and rewrites the satellite point buffers from the two most recent snapshots.
//  Everything else — input, picking, selection — happens on the main thread and
//  talks to the render thread only through `CameraRig`'s lock and
//  `SnapshotBuffer`.
//

import AppKit
import SceneKit
import SwiftUI
import simd

// MARK: - SwiftUI bridge

struct GlobeView: NSViewRepresentable {

    let scene: GlobeScene
    let buffer: SnapshotBuffer

    var onSelect: (Int?) -> Void
    var onHover: (Int?) -> Void
    var onFocusCoordinate: (Double, Double) -> Void
    var onResetCamera: () -> Void
    var onViewReady: (GlobeSCNView) -> Void = { _ in }

    func makeCoordinator() -> GlobeCoordinator {
        GlobeCoordinator(rig: scene.rig,
                         satellites: scene.satellites,
                         buffer: buffer)
    }

    func makeNSView(context: Context) -> GlobeSCNView {
        let view = GlobeSCNView()
        view.scene = scene.scene
        view.pointOfView = scene.cameraNode
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.isPlaying = true
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.isJitteringEnabled = false
        view.showsStatistics = false
        view.backgroundColor = NSColor(srgbRed: 0.012, green: 0.020, blue: 0.039, alpha: 1)

        context.coordinator.view = view
        scene.orbits.attachCamera(scene.cameraNode)
        configure(view, coordinator: context.coordinator)
        onViewReady(view)
        return view
    }

    func updateNSView(_ view: GlobeSCNView, context: Context) {
        context.coordinator.view = view
        configure(view, coordinator: context.coordinator)
    }

    private func configure(_ view: GlobeSCNView, coordinator: GlobeCoordinator) {
        coordinator.onSelect = onSelect
        coordinator.onHover = onHover

        view.onDrag = { [weak scene] dx, dy in
            guard let scene else { return }
            scene.orbit(dx: dx, dy: dy, viewportHeight: view.bounds.height)
        }
        view.onZoom = { [weak scene] factor in
            scene?.zoom(by: factor)
        }
        view.onPick = { [weak coordinator] point in
            coordinator?.pick(at: point, in: view)
        }
        view.onSelect = { [weak coordinator] index in
            coordinator?.onSelect?(index)
        }
        view.onHover = { [weak coordinator] index in
            coordinator?.onHover?(index)
        }
        view.onFocusPoint = { point in
            guard let coordinate = view.surfaceCoordinate(at: point) else { return }
            onFocusCoordinate(coordinate.lat, coordinate.lon)
        }
        view.onReset = onResetCamera
    }
}

// MARK: - Render coordinator

final class GlobeCoordinator: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {

    private let rig: CameraRig
    private let satellites: SatelliteLayer
    private let buffer: SnapshotBuffer

    weak var view: GlobeSCNView?
    var onSelect: ((Int?) -> Void)?
    var onHover: ((Int?) -> Void)?

    private var lastFrame: TimeInterval = 0

    /// How close to a satellite's projected centre a click must land, in points.
    static let pickRadius: CGFloat = 13

    init(rig: CameraRig, satellites: SatelliteLayer, buffer: SnapshotBuffer) {
        self.rig = rig
        self.satellites = satellites
        self.buffer = buffer
        super.init()
    }

    // MARK: Render thread

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = lastFrame == 0 ? 1.0 / 60.0 : min(0.25, max(0, time - lastFrame))
        lastFrame = time
        rig.step(dt: Float(dt))

        let pair = buffer.pair()
        guard pair.current.count > 0 else { return }
        satellites.update(previous: pair.previous,
                          current: pair.current,
                          alpha: Self.interpolationAlpha(previous: pair.previous,
                                                         current: pair.current))
    }

    /// Fraction of the way from `previous` to `current` at the present instant.
    ///
    /// Snapshots arrive at the tick rate; each one becomes the *target* of a
    /// one-interval ease, so motion is continuous and the alpha resets to zero
    /// exactly as the next snapshot lands.
    static func interpolationAlpha(previous: SatelliteSnapshot,
                                   current: SatelliteSnapshot) -> Float {
        let now = Date().timeIntervalSinceReferenceDate
        let span = current.time.timeIntervalSinceReferenceDate
            - previous.time.timeIntervalSinceReferenceDate
        guard span > 0.01 else { return 1 }
        let elapsed = now - current.time.timeIntervalSinceReferenceDate
        return Float(min(1, max(0, elapsed / span)))
    }

    // MARK: Picking (main thread)

    /// Nearest satellite within `pickRadius` points, ignoring anything hidden
    /// behind the globe.
    @MainActor
    func pick(at point: CGPoint, in view: SCNView) -> Int? {
        let current = buffer.pair().current
        guard current.count > 0 else { return nil }

        let pose = rig.currentPose()
        let cameraDirection = GeoMath.unitVector(lat: Double(pose.latitude),
                                                 lon: Double(pose.longitude))
        // A surface point is visible from distance d when cos(angle) ≥ 1/d.
        let horizon = 1 / pose.distance

        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for layer in satellites.layers.values where !layer.node.isHidden {
            for index in layer.indices where current.valid[index] {
                let position = current.positions[index]
                guard simd_dot(simd_normalize(position), cameraDirection) >= horizon else { continue }
                let projected = view.projectPoint(SCNVector3(position.x, position.y, position.z))
                guard projected.z > 0, projected.z < 1 else { continue }
                let dx = CGFloat(projected.x) - point.x
                let dy = CGFloat(projected.y) - point.y
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
        }
        return bestDistance <= Self.pickRadius ? bestIndex : nil
    }
}

// MARK: - SCNView subclass

/// Handles pointer input and stops rendering when the window is occluded.
final class GlobeSCNView: SCNView {

    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onPick: (@MainActor (CGPoint) -> Int?)?
    var onSelect: ((Int?) -> Void)?
    var onHover: ((Int?) -> Void)?
    var onFocusPoint: ((CGPoint) -> Void)?
    var onReset: (() -> Void)?

    private var trackingAreaRef: NSTrackingArea?
    private var lastLocation: NSPoint?
    private var dragTravel: CGFloat = 0
    private var hoveredIndex: Int?
    private var lastHoverCheck: TimeInterval = 0

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: hoveredIndex == nil ? .arrow : .pointingHand)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastLocation = convert(event.locationInWindow, from: nil)
        dragTravel = 0
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let previous = lastLocation else {
            lastLocation = location
            return
        }
        let dx = location.x - previous.x
        let dy = location.y - previous.y
        lastLocation = location
        dragTravel += abs(dx) + abs(dy)
        if dragTravel > 2 { setHovered(nil) }
        onDrag?(dx, dy)
    }

    override func mouseUp(with event: NSEvent) {
        defer { lastLocation = nil }
        guard dragTravel <= 2 else { return }
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount >= 2 {
            onFocusPoint?(point)
        } else {
            onSelect?(onPick?(point) ?? nil)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHoverCheck > 0.09 else { return }
        lastHoverCheck = now
        let point = convert(event.locationInWindow, from: nil)
        setHovered(onPick?(point) ?? nil)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func setHovered(_ index: Int?) {
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        onHover?(index)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Zoom

    override func scrollWheel(with event: NSEvent) {
        let raw = event.scrollingDeltaY
        guard raw != 0 else { return }
        let delta = event.hasPreciseScrollingDeltas ? raw * 0.006 : raw * 0.10
        onZoom?(CGFloat(exp(-Double(delta))))
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 / (1 + max(-0.8, event.magnification)))
    }

    override func smartMagnify(with event: NSEvent) {
        onReset?()
    }

    // MARK: Geometry

    /// Where a screen point meets the globe, in degrees.
    func surfaceCoordinate(at point: CGPoint, radius: Float = EarthNode.radius) -> (lat: Double, lon: Double)? {
        let near = unprojectPoint(SCNVector3(point.x, point.y, 0))
        let far = unprojectPoint(SCNVector3(point.x, point.y, 1))
        let origin = SIMD3<Float>(Float(near.x), Float(near.y), Float(near.z))
        let target = SIMD3<Float>(Float(far.x), Float(far.y), Float(far.z))
        let direction = target - origin
        guard simd_length_squared(direction) > 1e-12 else { return nil }
        let ray = simd_normalize(direction)

        let b = simd_dot(origin, ray)
        let c = simd_dot(origin, origin) - radius * radius
        let discriminant = b * b - c
        guard discriminant >= 0 else { return nil }
        let t = -b - discriminant.squareRoot()
        guard t > 0 else { return nil }
        return GeoMath.latLon(from: origin + ray * t)
    }

    // MARK: Occlusion

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self,
                                                  name: NSWindow.didChangeOcclusionStateNotification,
                                                  object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification,
                                               object: window)
        occlusionChanged()
    }

    @objc private func occlusionChanged() {
        // A minimised or fully covered window has nothing to draw; stopping the
        // loop here is what keeps idle CPU near zero.
        let visible = window?.occlusionState.contains(.visible) ?? true
        isPlaying = visible
        rendersContinuously = visible
        if visible { needsDisplay = true }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

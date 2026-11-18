//
//  OrbitTrackLayer.swift
//  Caelus
//
//  The selected satellite's orbit path, its ground track (past dim, future
//  bright) and the pulsing marker that sits on the satellite itself.
//

import AppKit
import SceneKit
import simd

@MainActor
final class OrbitTrackLayer {

    let root = SCNNode()

    private let orbitNode = SCNNode()
    private let groundNode = SCNNode()
    private let marker = SelectionMarker()

    init() {
        root.name = "orbit-track"
        orbitNode.renderingOrder = 20
        groundNode.renderingOrder = 21
        root.addChildNode(orbitNode)
        root.addChildNode(groundNode)
        root.addChildNode(marker.root)
    }

    // MARK: - Tracks

    /// Rebuild both tracks from geodetic samples.
    ///
    /// - Parameters:
    ///   - samples: Ordered samples with signed offsets from "now".
    ///   - color: The satellite's group colour.
    ///   - showOrbit: Draw the inertial orbit path.
    ///   - showGround: Draw the surface ground track.
    func update(samples: [TrackSample],
                color: NSColor,
                showOrbit: Bool,
                showGround: Bool) {
        orbitNode.isHidden = !showOrbit
        groundNode.isHidden = !showGround
        guard !samples.isEmpty else {
            orbitNode.childNodes.forEach { $0.removeFromParentNode() }
            groundNode.childNodes.forEach { $0.removeFromParentNode() }
            return
        }

        if showOrbit {
            let runs = Self.runs(of: samples) { sample in
                GeoMath.scenePosition(lat: sample.latitude,
                                      lon: sample.longitude,
                                      altKm: sample.altitudeKm)
            }
            replaceChildren(of: orbitNode, with: [
                Self.polylineNode(runs: runs,
                                  color: color.withAlphaComponent(0.85),
                                  blending: .add,
                                  width: 1.0),
            ])
        }

        if showGround {
            let past = samples.filter { $0.offsetMinutes <= 0 }
            let future = samples.filter { $0.offsetMinutes >= 0 }

            let pastRuns = Self.runs(of: past) { sample in
                GeoMath.scenePosition(lat: sample.latitude, lon: sample.longitude, radius: 1.0025)
            }
            let futureRuns = Self.runs(of: future) { sample in
                GeoMath.scenePosition(lat: sample.latitude, lon: sample.longitude, radius: 1.0025)
            }

            replaceChildren(of: groundNode, with: [
                Self.polylineNode(runs: pastRuns,
                                  color: color.withAlphaComponent(0.22),
                                  blending: .alpha,
                                  width: 1.0),
                Self.polylineNode(runs: futureRuns,
                                  color: color.withAlphaComponent(0.95),
                                  blending: .add,
                                  width: 1.0),
            ])
        }
    }

    func clear() {
        orbitNode.childNodes.forEach { $0.removeFromParentNode() }
        groundNode.childNodes.forEach { $0.removeFromParentNode() }
        marker.setVisible(false)
    }

    // MARK: - Marker

    func setMarker(position: SIMD3<Float>?, color: NSColor) {
        guard let position else {
            marker.setVisible(false)
            return
        }
        marker.setVisible(true)
        marker.root.simdPosition = position
        marker.setColor(color)
    }

    /// Keep the marker a constant size on screen.
    func attachCamera(_ camera: SCNNode) {
        marker.attachCamera(camera)
    }

    func setLineOfSight(from origin: SIMD3<Float>?, to target: SIMD3<Float>?) {
        marker.setLineOfSight(from: origin, to: target)
    }

    // MARK: - Geometry helpers

    /// Group samples into continuous runs, splitting where the sampling gaps.
    private static func runs(of samples: [TrackSample],
                             project: (TrackSample) -> SIMD3<Float>) -> [[SCNVector3]] {
        guard !samples.isEmpty else { return [] }
        var result: [[SCNVector3]] = []
        var current: [SCNVector3] = []

        for sample in samples {
            if let last = current.last {
                let position = project(sample)
                let previous = SIMD3<Float>(Float(last.x), Float(last.y), Float(last.z))
                if simd_distance(previous, position) > 0.35 {
                    if current.count > 1 { result.append(current) }
                    current = []
                }
            }
            let position = project(sample)
            current.append(SCNVector3(position.x, position.y, position.z))
        }
        if current.count > 1 { result.append(current) }
        return result
    }

    private static func polylineNode(runs: [[SCNVector3]],
                                     color: NSColor,
                                     blending: SCNBlendMode,
                                     width: CGFloat) -> SCNNode {
        let node = SCNNode()
        node.name = "polyline"
        guard !runs.isEmpty else { return node }

        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []
        for run in runs where run.count > 1 {
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: run)
            for i in 0..<(run.count - 1) {
                indices.append(base + UInt32(i))
                indices.append(base + UInt32(i + 1))
            }
        }
        guard !indices.isEmpty else { return node }

        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                                   elements: [SCNGeometryElement(indices: indices,
                                                                 primitiveType: .line)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.blendMode = blending
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.isDoubleSided = true
        geometry.materials = [material]
        node.geometry = geometry
        return node
    }

    private func replaceChildren(of parent: SCNNode, with nodes: [SCNNode]) {
        parent.childNodes.forEach { $0.removeFromParentNode() }
        for node in nodes { parent.addChildNode(node) }
    }
}

// MARK: - Selection marker

/// A billboarded glow with a pulsing ring, drawn on the selected satellite.
@MainActor
final class SelectionMarker {

    let root = SCNNode()

    private let scaleNode = SCNNode()
    private let glowNode: SCNNode
    private let ringNode: SCNNode

    init() {
        root.name = "selection-marker"

        let glowPlane = SCNPlane(width: 1, height: 1)
        let glowMaterial = SCNMaterial()
        glowMaterial.lightingModel = .constant
        glowMaterial.diffuse.contents = Self.glowImage()
        glowMaterial.blendMode = .add
        glowMaterial.writesToDepthBuffer = false
        glowMaterial.readsFromDepthBuffer = true
        glowMaterial.isDoubleSided = true
        glowPlane.materials = [glowMaterial]
        glowNode = SCNNode(geometry: glowPlane)
        glowNode.constraints = [SCNBillboardConstraint()]
        glowNode.renderingOrder = 30

        let ringPlane = SCNPlane(width: 1, height: 1)
        let ringMaterial = SCNMaterial()
        ringMaterial.lightingModel = .constant
        ringMaterial.diffuse.contents = Self.ringImage()
        ringMaterial.blendMode = .add
        ringMaterial.writesToDepthBuffer = false
        ringMaterial.readsFromDepthBuffer = true
        ringMaterial.isDoubleSided = true
        ringPlane.materials = [ringMaterial]
        ringNode = SCNNode(geometry: ringPlane)
        ringNode.constraints = [SCNBillboardConstraint()]
        ringNode.renderingOrder = 31

        root.addChildNode(scaleNode)
        scaleNode.addChildNode(glowNode)
        scaleNode.addChildNode(ringNode)
        root.isHidden = true

        let pulse = SCNAction.sequence([
            SCNAction.group([
                SCNAction.scale(to: 2.1, duration: 1.9),
                SCNAction.fadeOpacity(to: 0.0, duration: 1.9),
            ]),
            SCNAction.group([
                SCNAction.scale(to: 0.85, duration: 0),
                SCNAction.fadeOpacity(to: 0.9, duration: 0),
            ]),
        ])
        ringNode.runAction(.repeatForever(pulse))
    }

    func setVisible(_ visible: Bool) {
        root.isHidden = !visible
    }

    func setColor(_ color: NSColor) {
        (glowNode.geometry?.firstMaterial?.diffuse.contents as? NSImage)?.isTemplate = false
        glowNode.geometry?.firstMaterial?.multiply.contents = color
        ringNode.geometry?.firstMaterial?.multiply.contents = color
    }

    /// Scale the marker so it covers a constant fraction of the screen, no
    /// matter how far the camera is. Runs inside SceneKit's update phase, so it
    /// costs nothing on the main thread.
    func attachCamera(_ camera: SCNNode) {
        scaleNode.constraints = [Self.scaleConstraint(camera: camera)]
    }

    /// Deliberately `nonisolated`: SceneKit evaluates constraints on its render
    /// thread, so the block must not inherit the main actor.
    private nonisolated static func scaleConstraint(camera: SCNNode) -> SCNTransformConstraint {
        let constraint = SCNTransformConstraint(inWorldSpace: false) { [weak camera] node, _ in
            guard let camera else { return SCNMatrix4Identity }
            let anchor = node.parent?.simdWorldPosition ?? node.simdWorldPosition
            let distance = simd_distance(anchor, camera.simdWorldPosition)
            let scale = CGFloat(min(0.10, max(0.0035, distance * 0.0115)))
            return SCNMatrix4MakeScale(scale, scale, scale)
        }
        constraint.isIncremental = false
        return constraint
    }

    private let lineOfSight = SCNNode()

    func setLineOfSight(from origin: SIMD3<Float>?, to target: SIMD3<Float>?) {
        lineOfSight.childNodes.forEach { $0.removeFromParentNode() }
        guard let origin, let target else { return }

        let vertices = [SCNVector3(origin.x, origin.y, origin.z),
                        SCNVector3(target.x, target.y, target.z)]
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                                   elements: [SCNGeometryElement(indices: [0, 1], primitiveType: .line)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(srgbRed: 0.31, green: 0.70, blue: 1.0, alpha: 0.45)
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 25
        lineOfSight.addChildNode(node)
    }

    // MARK: Textures

    private static func glowImage(size: CGFloat = 128) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let colors = [
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1.0),
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55),
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
            ] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: colors,
                                            locations: [0, 0.22, 1]) else { return false }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            context.drawRadialGradient(gradient,
                                       startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: rect.width / 2,
                                       options: [])
            return true
        }
    }

    private static func ringImage(size: CGFloat = 128) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let inset = rect.width * 0.10
            let circle = rect.insetBy(dx: inset, dy: inset)
            context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.setLineWidth(rect.width * 0.035)
            context.strokeEllipse(in: circle)
            // A soft second ring keeps it from looking like a hairline.
            context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.25))
            context.setLineWidth(rect.width * 0.10)
            context.strokeEllipse(in: circle)
            return true
        }
    }
}

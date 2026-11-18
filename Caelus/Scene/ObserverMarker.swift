//
//  ObserverMarker.swift
//  Caelus
//
//  The ground station: a pin, a target ring on the surface, and a faint great
//  circle marking the observer's horizon plane.
//

import AppKit
import SceneKit
import simd

@MainActor
final class ObserverMarker {

    let root = SCNNode()

    private let pinNode = SCNNode()
    private let ringNode = SCNNode()
    private let horizonNode = SCNNode()
    private let dotNode = SCNNode()

    private static let accent = NSColor(srgbRed: 0.31, green: 0.70, blue: 1.0, alpha: 1.0)

    init() {
        root.name = "observer"
        root.addChildNode(pinNode)
        root.addChildNode(ringNode)
        root.addChildNode(horizonNode)
        root.addChildNode(dotNode)

        let sphere = SCNSphere(radius: 0.006)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = Self.accent
        material.emission.contents = Self.accent
        material.writesToDepthBuffer = false
        sphere.materials = [material]
        dotNode.geometry = sphere
        dotNode.renderingOrder = 40

        let pulse = SCNAction.sequence([
            SCNAction.scale(to: 1.6, duration: 1.4),
            SCNAction.scale(to: 1.0, duration: 1.4),
        ])
        dotNode.runAction(.repeatForever(pulse))
    }

    func update(site: ObserverSite) {
        let unit = GeoMath.unitVector(lat: site.latitude, lon: site.longitude)

        // Target ring on the surface.
        let ringPoints = Self.circle(center: unit, angularRadius: 1.1 * .pi / 180,
                                     radius: 1.0035, segments: 72)
        Self.replaceGeometry(of: ringNode,
                             with: Self.lineGeometry(points: ringPoints,
                                                     color: Self.accent.withAlphaComponent(0.85),
                                                     blending: .add))

        // Horizon: a great circle in the tangent plane.
        let horizonPoints = Self.circle(center: unit, angularRadius: .pi / 2,
                                        radius: 1.0015, segments: 180)
        Self.replaceGeometry(of: horizonNode,
                             with: Self.lineGeometry(points: horizonPoints,
                                                     color: Self.accent.withAlphaComponent(0.10),
                                                     blending: .add))

        // Pin from the surface outward.
        let base = unit * 1.0
        let tip = unit * 1.045
        Self.replaceGeometry(of: pinNode,
                             with: Self.lineGeometry(points: [base, tip],
                                                     color: Self.accent.withAlphaComponent(0.55),
                                                     blending: .add))
        dotNode.simdPosition = tip
    }

    func setVisible(_ visible: Bool) {
        root.isHidden = !visible
    }

    // MARK: - Geometry

    /// Points on a small circle at a fixed angular distance from `center`.
    private static func circle(center: SIMD3<Float>,
                               angularRadius: Float,
                               radius: Float,
                               segments: Int) -> [SIMD3<Float>] {
        let u = simd_normalize(center)
        var helper = SIMD3<Float>(0, 1, 0)
        if abs(simd_dot(u, helper)) > 0.95 { helper = SIMD3<Float>(1, 0, 0) }
        let e1 = simd_normalize(simd_cross(helper, u))
        let e2 = simd_cross(u, e1)

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(segments + 1)
        for i in 0...segments {
            let angle = Float(i) / Float(segments) * 2 * .pi
            let direction = cos(angularRadius) * u
                + sin(angularRadius) * (cos(angle) * e1 + sin(angle) * e2)
            points.append(simd_normalize(direction) * radius)
        }
        return points
    }

    private static func lineGeometry(points: [SIMD3<Float>],
                                     color: NSColor,
                                     blending: SCNBlendMode) -> SCNGeometry? {
        guard points.count > 1 else { return nil }
        let vertices = points.map { SCNVector3($0.x, $0.y, $0.z) }
        var indices: [UInt32] = []
        indices.reserveCapacity((points.count - 1) * 2)
        for i in 0..<(points.count - 1) {
            indices.append(UInt32(i))
            indices.append(UInt32(i + 1))
        }
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
        return geometry
    }

    private static func replaceGeometry(of node: SCNNode, with geometry: SCNGeometry?) {
        node.geometry = geometry
        node.renderingOrder = 40
    }
}

//
//  StarField.swift
//  Caelus
//
//  A procedural sky: a few thousand stars with a realistic brightness
//  distribution plus a faint Milky Way band. No asset, no network.
//

import AppKit
import SceneKit
import simd

enum StarField {

    @MainActor
    static func make(radius: Float = 70, scale: CGFloat = 2) -> SCNNode {
        let node = SCNNode()
        node.name = "stars"
        node.renderingOrder = -10

        var rng = SeededGenerator(seed: 0x5A7_7A11_2E5E_0001)

        // Brightness buckets: most stars are faint, a handful are bright.
        struct Bucket {
            let size: CGFloat
            let alpha: CGFloat
            let color: NSColor
            var points: [SCNVector3] = []
        }

        var buckets: [Bucket] = [
            Bucket(size: 1.0, alpha: 0.30, color: NSColor(srgbRed: 0.62, green: 0.72, blue: 0.88, alpha: 1)),
            Bucket(size: 1.3, alpha: 0.52, color: NSColor(srgbRed: 0.78, green: 0.85, blue: 0.96, alpha: 1)),
            Bucket(size: 1.8, alpha: 0.78, color: NSColor(srgbRed: 0.92, green: 0.95, blue: 1.00, alpha: 1)),
            Bucket(size: 2.6, alpha: 1.00, color: NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)),
            Bucket(size: 1.6, alpha: 0.60, color: NSColor(srgbRed: 1.00, green: 0.86, blue: 0.70, alpha: 1)),
        ]

        let total = 5_200
        for _ in 0..<total {
            let direction = randomDirection(&rng)
            let magnitude = pow(Double(rng.nextUnit()), 2.6)      // skew toward faint

            let index: Int
            switch magnitude {
            case ..<0.42: index = 0
            case ..<0.72: index = 1
            case ..<0.90: index = 2
            case ..<0.985: index = 3
            default: index = rng.nextUnit() < 0.55 ? 4 : 3
            }

            buckets[index].points.append(SCNVector3(direction.x * radius,
                                                    direction.y * radius,
                                                    direction.z * radius))
        }

        // Milky Way: a scatter around a tilted great circle.
        let tilt = simd_quatf(angle: .pi / 3.1, axis: simd_normalize(SIMD3<Float>(0.35, 0.2, 1)))
        for _ in 0..<2_600 {
            let angle = Float(rng.nextUnit()) * 2 * .pi
            let spread = Float(gaussian(&rng)) * 0.16
            var point = SIMD3<Float>(cos(angle), sin(angle), 0)
            point += SIMD3<Float>(0, 0, spread)
            point = simd_normalize(tilt.act(point)) * radius
            buckets[0].points.append(SCNVector3(point.x, point.y, point.z))
        }

        for bucket in buckets where !bucket.points.isEmpty {
            let element = SCNGeometryElement(indices: (0..<UInt32(bucket.points.count)).map { $0 },
                                             primitiveType: .point)
            // Pin the point to a constant screen-space radius so stars do not
            // swell as the camera dollies in.
            let radius = bucket.size * scale / 2
            element.minimumPointScreenSpaceRadius = radius
            element.maximumPointScreenSpaceRadius = radius

            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: bucket.points)],
                                       elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = bucket.color
            material.blendMode = .add
            material.writesToDepthBuffer = false
            material.readsFromDepthBuffer = false
            material.isDoubleSided = true
            geometry.materials = [material]

            let child = SCNNode(geometry: geometry)
            child.renderingOrder = -10
            node.addChildNode(child)
        }

        return node
    }

    // MARK: - Random helpers

    private static func randomDirection(_ rng: inout SeededGenerator) -> SIMD3<Float> {
        let z = Float(rng.nextUnit()) * 2 - 1
        let theta = Float(rng.nextUnit()) * 2 * .pi
        let r = (max(0, 1 - z * z)).squareRoot()
        return SIMD3<Float>(r * cos(theta), z, r * sin(theta))
    }

    /// Box–Muller, clamped so a stray outlier cannot draw a line across the sky.
    private static func gaussian(_ rng: inout SeededGenerator) -> Double {
        let u1 = max(1e-9, rng.nextUnit())
        let u2 = rng.nextUnit()
        let value = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        return max(-2.5, min(2.5, value))
    }
}

/// Deterministic SplitMix64 so the sky looks the same on every launch.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

//
//  SatelliteLayer.swift
//  Caelus
//
//  One point cloud per render group. Positions live in a pre-allocated Metal
//  buffer that the render thread rewrites in place each frame, interpolating
//  between the two most recent propagation snapshots — no per-frame allocation,
//  no geometry rebuilds.
//
//  Each group draws twice: a crisp core and a wide additive halo, which reads as
//  a soft glow against the black sky.
//

import AppKit
import Metal
import SceneKit
import simd

final class SatelliteLayer: @unchecked Sendable {

    struct Layer {
        let group: SatelliteGroup
        let buffer: MTLBuffer
        let indices: [Int]
        let count: Int
        let coreElement: SCNGeometryElement
        let haloElement: SCNGeometryElement
        let node: SCNNode
    }

    /// Radius of the core point in points (multiplied by the display scale).
    private var baseRadius: CGFloat
    private var screenScale: CGFloat

    private(set) var layers: [SatelliteGroup: Layer] = [:]

    init(renderIndices: [SatelliteGroup: [Int]],
         baseRadius: CGFloat,
         screenScale: CGFloat) {
        self.baseRadius = baseRadius
        self.screenScale = screenScale

        guard let device = MTLCreateSystemDefaultDevice() else { return }

        for group in SatelliteGroup.renderPriority {
            guard let indices = renderIndices[group], !indices.isEmpty else { continue }
            let count = indices.count
            let stride = MemoryLayout<SIMD3<Float>>.stride
            guard let buffer = device.makeBuffer(length: count * stride,
                                                 options: .storageModeShared) else { continue }

            let source = SCNGeometrySource(buffer: buffer,
                                           vertexFormat: .float3,
                                           semantic: .vertex,
                                           vertexCount: count,
                                           dataOffset: 0,
                                           dataStride: stride)

            let indexList = (0..<UInt32(count)).map { $0 }
            let coreElement = SCNGeometryElement(indices: indexList, primitiveType: .point)
            let haloElement = SCNGeometryElement(indices: indexList, primitiveType: .point)

            let coreGeometry = SCNGeometry(sources: [source], elements: [coreElement])
            let haloGeometry = SCNGeometry(sources: [source], elements: [haloElement])

            let core = SCNMaterial()
            core.lightingModel = .constant
            core.diffuse.contents = NSColor(group.color)
            core.blendMode = .alpha
            core.writesToDepthBuffer = false
            core.readsFromDepthBuffer = true
            core.isDoubleSided = true
            coreGeometry.materials = [core]

            let halo = SCNMaterial()
            halo.lightingModel = .constant
            halo.diffuse.contents = NSColor(group.color)
                .withAlphaComponent(group == .starlink ? 0.05 : 0.11)
            halo.blendMode = .add
            halo.writesToDepthBuffer = false
            halo.readsFromDepthBuffer = true
            halo.isDoubleSided = true
            haloGeometry.materials = [halo]

            let node = SCNNode(geometry: coreGeometry)
            node.name = "satellites-\(group.rawValue)"
            node.renderingOrder = 10

            let haloNode = SCNNode(geometry: haloGeometry)
            haloNode.renderingOrder = 9
            node.addChildNode(haloNode)

            let layer = Layer(group: group,
                              buffer: buffer,
                              indices: indices,
                              count: count,
                              coreElement: coreElement,
                              haloElement: haloElement,
                              node: node)
            layers[group] = layer
            applyPointSize(to: layer)
        }
    }

    // MARK: - Sizing

    func setPointRadius(_ radius: CGFloat, screenScale: CGFloat) {
        self.baseRadius = radius
        self.screenScale = screenScale
        for layer in layers.values { applyPointSize(to: layer) }
    }

    private func applyPointSize(to layer: Layer) {
        let core = baseRadius * layer.group.pointScale * screenScale
        let halo = core * 2.35
        layer.coreElement.minimumPointScreenSpaceRadius = core
        layer.coreElement.maximumPointScreenSpaceRadius = core
        layer.haloElement.minimumPointScreenSpaceRadius = halo
        layer.haloElement.maximumPointScreenSpaceRadius = halo
    }

    func setVisible(_ group: SatelliteGroup, _ visible: Bool) {
        layers[group]?.node.isHidden = !visible
    }

    func setAllVisible(_ visible: Bool) {
        for layer in layers.values { layer.node.isHidden = !visible }
    }

    // MARK: - Per-frame update

    /// Rewrite every visible group's buffer with the interpolated positions.
    ///
    /// `alpha` is the fraction of the way from `previous` to `current`. A plain
    /// linear interpolation is used: over a one-second step the chord/arc error
    /// is well under a metre, far below one screen pixel at any zoom.
    func update(previous: SatelliteSnapshot,
                current: SatelliteSnapshot,
                alpha: Float) {
        guard current.count > 0 else { return }
        let t = max(0, min(1, alpha))
        let canBlend = previous.count == current.count && previous.time != .distantPast

        for layer in layers.values where !layer.node.isHidden {
            let pointer = layer.buffer.contents().bindMemory(to: SIMD3<Float>.self,
                                                             capacity: layer.count)
            let indices = layer.indices
            let count = layer.count

            if canBlend {
                for i in 0..<count {
                    let index = indices[i]
                    guard current.valid[index] else {
                        pointer[i] = SIMD3<Float>(repeating: .nan)
                        continue
                    }
                    let next = current.positions[index]
                    if previous.valid[index] {
                        let prior = previous.positions[index]
                        pointer[i] = prior + (next - prior) * t
                    } else {
                        pointer[i] = next
                    }
                }
            } else {
                for i in 0..<count {
                    let index = indices[i]
                    pointer[i] = current.valid[index]
                        ? current.positions[index]
                        : SIMD3<Float>(repeating: .nan)
                }
            }
        }
    }

    /// Total number of points currently drawn.
    var pointCount: Int {
        layers.values.reduce(0) { $0 + $1.count }
    }
}

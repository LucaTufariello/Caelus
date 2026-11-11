//
//  EarthNode.swift
//  SatTracker
//
//  The globe: a UV sphere generated from `GeoMath`'s frame convention so the
//  equirectangular texture lands exactly where the maths says it should, a
//  day/night blend driven by the Sun direction, and a fresnel atmosphere shell.
//

import AppKit
import SceneKit
import simd

enum EarthNode {

    /// Radius of the globe in scene units.
    static let radius: Float = 1.0

    // MARK: - Assembly

    @MainActor
    static func make() -> SCNNode {
        let node = SCNNode()
        node.name = "earth"

        let geometry = sphereGeometry(radius: radius, segments: 256, rings: 128)
        geometry.materials = [earthMaterial()]
        node.geometry = geometry

        let atmosphere = SCNNode()
        atmosphere.name = "atmosphere"
        let shell = sphereGeometry(radius: radius * 1.032, segments: 160, rings: 80)
        shell.materials = [atmosphereMaterial()]
        atmosphere.geometry = shell
        atmosphere.renderingOrder = -1
        node.addChildNode(atmosphere)

        return node
    }

    // MARK: - Geometry

    /// UV sphere whose texture coordinates match `GeoMath.unitVector`.
    ///
    /// u = (lon + 180)/360, with lon −180 at u = 0.
    ///
    /// V is **inverted** relative to the usual (lat + 90)/180: SceneKit samples
    /// an `NSImage`-backed texture with v = 0 at the image's *top* row, while an
    /// equirectangular map has its north pole in that row. Without the flip the
    /// globe renders with latitudes mirrored — 30°S showing Greenland.
    ///
    /// Winding is counter-clockwise seen from outside.
    static func sphereGeometry(radius: Float, segments: Int, rings: Int) -> SCNGeometry {
        let columns = segments + 1
        let rows = rings + 1

        var vertices = [SCNVector3]()
        var normals = [SCNVector3]()
        var uvs = [CGPoint]()
        vertices.reserveCapacity(columns * rows)
        normals.reserveCapacity(columns * rows)
        uvs.reserveCapacity(columns * rows)

        for j in 0...rings {
            let v = Float(j) / Float(rings)
            let lat = -90 + 180 * Double(v)
            for i in 0...segments {
                let u = Float(i) / Float(segments)
                let lon = -180 + 360 * Double(u)
                let unit = GeoMath.unitVector(lat: lat, lon: lon)
                vertices.append(SCNVector3(unit.x * radius, unit.y * radius, unit.z * radius))
                normals.append(SCNVector3(unit.x, unit.y, unit.z))
                uvs.append(CGPoint(x: CGFloat(u), y: CGFloat(1 - v)))
            }
        }

        var indices = [UInt32]()
        indices.reserveCapacity(segments * rings * 6)
        for j in 0..<rings {
            for i in 0..<segments {
                let a = UInt32(j * columns + i)
                let b = a + 1
                let d = UInt32((j + 1) * columns + i)
                let c = d + 1
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }

        let sources = [
            SCNGeometrySource(vertices: vertices),
            SCNGeometrySource(normals: normals),
            SCNGeometrySource(textureCoordinates: uvs),
        ]
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: sources, elements: [element])
    }

    // MARK: - Materials

    @MainActor
    static func earthMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.name = "earth-surface"
        material.lightingModel = .blinn
        material.diffuse.contents = NSImage(named: "EarthDay")
        material.diffuse.mipFilter = .linear
        material.diffuse.magnificationFilter = .linear
        material.diffuse.minificationFilter = .linear
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp

        material.emission.contents = NSImage(named: "EarthNight")
        material.emission.intensity = 1.0
        material.emission.mipFilter = .linear

        material.specular.contents = NSImage(named: "EarthSpecular")
        material.specular.intensity = 0.55
        material.shininess = 0.22

        material.ambient.contents = NSColor(white: 0.018, alpha: 1)
        material.locksAmbientWithDiffuse = false

        material.shaderModifiers = [.surface: Self.dayNightShader]
        material.setValue(NSValue(scnVector3: SCNVector3(1, 0, 0)), forKey: "sunDirection")
        return material
    }

    @MainActor
    static func atmosphereMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.name = "atmosphere"
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.black
        material.isDoubleSided = false
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.shaderModifiers = [.surface: Self.atmosphereShader]
        material.setValue(NSValue(scnVector3: SCNVector3(1, 0, 0)), forKey: "sunDirection")
        return material
    }

    /// Push a new Sun direction into both materials.
    @MainActor
    static func updateSun(direction: SIMD3<Float>, earth: SCNNode) {
        let value = NSValue(scnVector3: SCNVector3(direction.x, direction.y, direction.z))
        earth.geometry?.firstMaterial?.setValue(value, forKey: "sunDirection")
        earth.childNode(withName: "atmosphere", recursively: false)?
            .geometry?.firstMaterial?.setValue(value, forKey: "sunDirection")
    }

    // MARK: - Shaders

    /// Night lights fade in as the surface turns away from the Sun; the day
    /// texture is lifted slightly on the lit side so the terminator reads.
    private static let dayNightShader = """
    #pragma arguments
    float3 sunDirection;

    #pragma body
    float3 n = normalize(_surface.normal);
    float3 l = normalize((scn_node.modelViewTransform * float4(sunDirection, 0.0)).xyz);
    float ndl = dot(n, l);

    // 1 on the night side, 0 in daylight, with a soft twilight band.
    float night = smoothstep(0.10, -0.18, ndl);
    _surface.emission.rgb *= night * 1.15;

    // Keep a hint of the surface visible at night so continents are not a void.
    float lift = smoothstep(-0.35, 0.25, ndl);
    _surface.diffuse.rgb *= mix(0.10, 1.0, lift);
    """

    /// A limb glow that only appears where the atmosphere is lit.
    private static let atmosphereShader = """
    #pragma arguments
    float3 sunDirection;

    #pragma body
    float3 n = normalize(_surface.normal);
    float3 v = normalize(_surface.view);
    float facing = saturate(dot(n, v));

    // A band that peaks just off the limb and fades to nothing at the shell's
    // silhouette, so the glow has no hard outer edge.
    float rim = pow(1.0 - facing, 3.0);
    float edge = smoothstep(0.0, 0.42, facing);
    float glow = rim * edge;

    float3 l = normalize((scn_node.modelViewTransform * float4(sunDirection, 0.0)).xyz);
    float lit = smoothstep(-0.45, 0.32, dot(n, l));

    float3 cool = float3(0.06, 0.17, 0.38);
    float3 warm = float3(0.36, 0.66, 1.00);
    float3 tint = mix(cool, warm, lit);

    _surface.diffuse = float4(tint * glow * (0.16 + 1.35 * lit), 1.0);
    """
}

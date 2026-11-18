//
//  EarthNodeTests.swift
//  CaelusTests
//
//  The globe's texture alignment. Satellites are placed with
//  `GeoMath.unitVector`, and the Earth mesh is built from the same function, so
//  a wrong texture coordinate does not move the satellites — it silently paints
//  the continents under the wrong ones. That is exactly what happened once: the
//  V axis was inverted and 30°S rendered Greenland.
//

import XCTest
import AppKit
import SceneKit
import simd
@testable import Caelus

final class EarthNodeTests: XCTestCase {

    // MARK: - Geometry

    /// Reads a geometry source as flat `Float` components.
    ///
    /// `SCNGeometrySource.vector3(at:)` and `textureCoordinate(at:)` are iOS
    /// only, so on macOS the buffer has to be walked by hand.
    private func components(of source: SCNGeometrySource) -> [Float] {
        let per = source.componentsPerVector
        let count = source.vectorCount
        let stride = source.dataStride
        let offset = source.dataOffset
        precondition(source.bytesPerComponent == 4, "expected 32-bit components")

        return source.data.withUnsafeBytes { raw in
            var out = [Float](repeating: 0, count: count * per)
            for index in 0..<count {
                for component in 0..<per {
                    out[index * per + component] = raw.loadUnaligned(
                        fromByteOffset: offset + index * stride + component * 4,
                        as: Float.self)
                }
            }
            return out
        }
    }

    /// Texture coordinate assigned to the vertex nearest `lat`/`lon`.
    private func uv(lat: Double, lon: Double,
                    in geometry: SCNGeometry) throws -> CGPoint {
        let vertexSource = try XCTUnwrap(geometry.sources(for: .vertex).first)
        let texcoordSource = try XCTUnwrap(geometry.sources(for: .texcoord).first)
        let vertices = components(of: vertexSource)
        let texcoords = components(of: texcoordSource)
        let target = GeoMath.unitVector(lat: lat, lon: lon)

        var bestIndex = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for index in 0..<vertexSource.vectorCount {
            let v = SIMD3<Float>(vertices[index * 3], vertices[index * 3 + 1], vertices[index * 3 + 2])
            let d = simd_distance(v, target)
            if d < bestDistance {
                bestDistance = d
                bestIndex = index
            }
        }
        // The mesh is dense enough that a vertex sits within a fraction of a
        // degree of any requested point.
        XCTAssertLessThan(bestDistance, 0.02, "no vertex near \(lat), \(lon)")
        return CGPoint(x: CGFloat(texcoords[bestIndex * 2]),
                       y: CGFloat(texcoords[bestIndex * 2 + 1]))
    }

    /// SceneKit samples an `NSImage`-backed texture with v = 0 at the image's
    /// **top** row, and an equirectangular map has its north pole in that row.
    /// So the north pole must be v = 0, not v = 1.
    func testTextureCoordinatesPutNorthAtTheTopOfTheImage() throws {
        let geometry = EarthNode.sphereGeometry(radius: 1, segments: 64, rings: 32)

        let north = try uv(lat: 89, lon: 0, in: geometry)
        let south = try uv(lat: -89, lon: 0, in: geometry)
        XCTAssertEqual(north.y, 0, accuracy: 0.02, "north pole must sample the top row")
        XCTAssertEqual(south.y, 1, accuracy: 0.02, "south pole must sample the bottom row")

        let antimeridian = try uv(lat: 0, lon: -179, in: geometry)
        let greenwich = try uv(lat: 0, lon: 0, in: geometry)
        XCTAssertEqual(antimeridian.x, 0, accuracy: 0.02, "lon −180 is the left edge")
        XCTAssertEqual(greenwich.x, 0.5, accuracy: 0.02, "lon 0 is the middle column")
    }

    // MARK: - Against the real texture

    /// The texture shipped in the bundle, read straight from the source tree so
    /// the test does not depend on how the asset catalog is compiled.
    private func earthTexture() throws -> NSBitmapImageRep {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // CaelusTests
            .deletingLastPathComponent()      // repo root
        let path = root
            .appendingPathComponent("Caelus/Resources/Assets.xcassets")
            .appendingPathComponent("EarthDay.imageset/EarthDay.jpg")
        let data = try Data(contentsOf: path)
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    /// Sample the map the way SceneKit will: v = 0 is the top row.
    private func colour(lat: Double, lon: Double,
                        in geometry: SCNGeometry,
                        texture: NSBitmapImageRep) throws -> (r: Double, g: Double, b: Double) {
        let coord = try uv(lat: lat, lon: lon, in: geometry)
        let x = min(texture.pixelsWide - 1, max(0, Int(coord.x * Double(texture.pixelsWide))))
        let y = min(texture.pixelsHigh - 1, max(0, Int(coord.y * Double(texture.pixelsHigh))))
        let c = try XCTUnwrap(texture.colorAt(x: x, y: y))
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    /// Land and ocean at mirrored latitudes. An inverted V swaps these two,
    /// which is the failure this file exists to catch.
    func testContinentsLandInTheRightHemisphere() throws {
        let geometry = EarthNode.sphereGeometry(radius: 1, segments: 256, rings: 128)
        let texture = try earthTexture()

        // Central United States: land, warm.
        let usa = try colour(lat: 40, lon: -100, in: geometry, texture: texture)
        XCTAssertGreaterThan(usa.r, usa.b, "40°N 100°W should be land, got \(usa)")

        // The South Pacific at the same longitude: open water, blue.
        let pacific = try colour(lat: -40, lon: -100, in: geometry, texture: texture)
        XCTAssertGreaterThan(pacific.b, pacific.r, "40°S 100°W should be ocean, got \(pacific)")

        // Congo basin: green.
        let congo = try colour(lat: 0, lon: 20, in: geometry, texture: texture)
        XCTAssertGreaterThan(congo.g, congo.b, "0° 20°E should be green, got \(congo)")

        // Central Pacific: blue.
        let midPacific = try colour(lat: 0, lon: -140, in: geometry, texture: texture)
        XCTAssertGreaterThan(midPacific.b, midPacific.r, "0° 140°W should be ocean, got \(midPacific)")
    }
}

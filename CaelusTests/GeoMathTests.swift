//
//  GeoMathTests.swift
//  CaelusTests
//
//  The scene's frame convention is the one thing every other layer depends on:
//  get it wrong and the ground tracks land in the wrong hemisphere.
//

import XCTest
import simd
import SatelliteKit
@testable import Caelus

final class GeoMathTests: XCTestCase {

    private let tolerance: Float = 1e-5

    // MARK: - Frame calibration

    func testEquatorPrimeMeridianIsPositiveX() {
        let p = GeoMath.unitVector(lat: 0, lon: 0)
        XCTAssertEqual(p.x, 1, accuracy: tolerance)
        XCTAssertEqual(p.y, 0, accuracy: tolerance)
        XCTAssertEqual(p.z, 0, accuracy: tolerance)
    }

    func testNorthPoleIsPositiveY() {
        let p = GeoMath.unitVector(lat: 90, lon: 0)
        XCTAssertEqual(p.x, 0, accuracy: tolerance)
        XCTAssertEqual(p.y, 1, accuracy: tolerance)
        XCTAssertEqual(p.z, 0, accuracy: tolerance)
    }

    func testSouthPoleIsNegativeY() {
        let p = GeoMath.unitVector(lat: -90, lon: 0)
        XCTAssertEqual(p.y, -1, accuracy: tolerance)
    }

    func testEastIsNegativeZ() {
        let p = GeoMath.unitVector(lat: 0, lon: 90)
        XCTAssertEqual(p.x, 0, accuracy: tolerance)
        XCTAssertEqual(p.y, 0, accuracy: tolerance)
        XCTAssertEqual(p.z, -1, accuracy: tolerance)
    }

    func testWestIsPositiveZ() {
        let p = GeoMath.unitVector(lat: 0, lon: -90)
        XCTAssertEqual(p.z, 1, accuracy: tolerance)
    }

    func testAntimeridianIsNegativeX() {
        let p = GeoMath.unitVector(lat: 0, lon: 180)
        XCTAssertEqual(p.x, -1, accuracy: tolerance)
    }

    func testLongitudeOffsetIsZero() {
        // The Earth node builds its own UV sphere from this convention, so the
        // texture's prime meridian and the frame's must coincide.
        XCTAssertEqual(GeoMath.longitudeOffset, 0)
    }

    // MARK: - Round trips

    func testUnitVectorRoundTrips() {
        for latitude in stride(from: -85.0, through: 85.0, by: 17.0) {
            for longitude in stride(from: -180.0, to: 180.0, by: 23.0) {
                let unit = GeoMath.unitVector(lat: latitude, lon: longitude)
                let back = GeoMath.latLon(from: unit)
                XCTAssertEqual(back.lat, latitude, accuracy: 1e-4)
                XCTAssertEqual(GeoMath.wrapLongitude(back.lon - longitude), 0, accuracy: 1e-4)
            }
        }
    }

    func testUnitVectorIsUnitLength() {
        for latitude in stride(from: -90.0, through: 90.0, by: 15.0) {
            let unit = GeoMath.unitVector(lat: latitude, lon: 37)
            XCTAssertEqual(simd_length(unit), 1, accuracy: tolerance)
        }
    }

    func testAltitudeScalesRadius() {
        let surface = GeoMath.scenePosition(lat: 41.9, lon: 12.5, altKm: 0)
        let orbit = GeoMath.scenePosition(lat: 41.9, lon: 12.5, altKm: 400)

        XCTAssertEqual(simd_length(surface), 1, accuracy: tolerance)
        XCTAssertEqual(simd_length(orbit), Float(1 + 400 / GeoMath.earthRadiusKm), accuracy: tolerance)
        // Same ray from the centre.
        XCTAssertEqual(simd_normalize(surface).x, simd_normalize(orbit).x, accuracy: tolerance)
    }

    // MARK: - Distances

    func testGreatCircleRomeToLondon() {
        let km = GeoMath.greatCircleKm(lat1: 41.9028, lon1: 12.4964,
                                       lat2: 51.5074, lon2: -0.1278)
        // Published great-circle distance is about 1435 km.
        XCTAssertEqual(km, 1435, accuracy: 10)
    }

    func testGreatCircleIsZeroForSamePoint() {
        XCTAssertEqual(GeoMath.greatCircleKm(lat1: 10, lon1: 20, lat2: 10, lon2: 20),
                       0, accuracy: 1e-6)
    }

    func testGreatCircleIsSymmetric() {
        let a = GeoMath.greatCircleKm(lat1: 41.9, lon1: 12.5, lat2: -33.87, lon2: 151.2)
        let b = GeoMath.greatCircleKm(lat1: -33.87, lon1: 151.2, lat2: 41.9, lon2: 12.5)
        XCTAssertEqual(a, b, accuracy: 1e-6)
    }

    // MARK: - Longitude wrapping

    func testWrapLongitude() {
        XCTAssertEqual(GeoMath.wrapLongitude(0), 0, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.wrapLongitude(179.5), 179.5, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.wrapLongitude(180), -180, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.wrapLongitude(181), -179, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.wrapLongitude(-181), 179, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.wrapLongitude(540), -180, accuracy: 1e-9)
    }

    // MARK: - Antimeridian split

    func testGroundTrackSplitsAtAntimeridian() {
        let points = [
            LatLonAlt(10, 178, 400),
            LatLonAlt(11, 179, 400),
            LatLonAlt(12, -179, 400),
            LatLonAlt(13, -178, 400),
        ]
        let runs = GeoMath.splitAtAntimeridian(points)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].count, 2)
        XCTAssertEqual(runs[1].count, 2)
    }

    func testContinuousTrackIsNotSplit() {
        let points = (0..<10).map { LatLonAlt(Double($0), Double($0) * 2, 400) }
        XCTAssertEqual(GeoMath.splitAtAntimeridian(points).count, 1)
    }
}

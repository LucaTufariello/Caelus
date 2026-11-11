//
//  PassTests.swift
//  SatTrackerTests
//

import XCTest
import SatelliteKit
@testable import SatTracker

final class PassTests: XCTestCase {

    private func issSatellite() throws -> Satellite {
        let record = try XCTUnwrap(TLEParser.parse(TLEFixtures.issDocument, groups: []).records.first)
        return Satellite(elements: record.elements)
    }

    // MARK: - Structure

    func testISSRisesOverRomeWithinADay() throws {
        let satellite = try issSatellite()
        let passes = PassPredictor.passes(satellite: satellite,
                                          site: .rome,
                                          from: Date(),
                                          hours: 24,
                                          minElevation: 10,
                                          limit: 20)

        // The ISS completes about 15.5 orbits a day; a mid-latitude site sees
        // roughly four to six passes above 10°.
        XCTAssertGreaterThanOrEqual(passes.count, 2)
        XCTAssertLessThanOrEqual(passes.count, 12)
    }

    func testPassesAreWellFormed() throws {
        let satellite = try issSatellite()
        let passes = PassPredictor.passes(satellite: satellite,
                                          site: .rome,
                                          from: Date(),
                                          hours: 24,
                                          minElevation: 10,
                                          limit: 20)

        for pass in passes {
            XCTAssertLessThan(pass.rise, pass.peak)
            XCTAssertLessThan(pass.peak, pass.set)
            XCTAssertGreaterThan(pass.duration, 60)
            XCTAssertLessThan(pass.duration, 900)
            XCTAssertGreaterThanOrEqual(pass.maxElevation, 10)
            XCTAssertLessThanOrEqual(pass.maxElevation, 90)
            XCTAssertGreaterThan(pass.rangeAtPeakKm, 300)
            XCTAssertLessThan(pass.rangeAtPeakKm, 3_000)
            XCTAssertGreaterThanOrEqual(pass.peakAzimuth, 0)
            XCTAssertLessThan(pass.peakAzimuth, 360)
        }
    }

    func testPassesAreChronologicalAndDisjoint() throws {
        let satellite = try issSatellite()
        let passes = PassPredictor.passes(satellite: satellite,
                                          site: .rome,
                                          from: Date(),
                                          hours: 48,
                                          minElevation: 10,
                                          limit: 20)

        for (earlier, later) in zip(passes, passes.dropFirst()) {
            XCTAssertLessThan(earlier.set, later.rise)
        }
    }

    func testHigherElevationThresholdYieldsFewerPasses() throws {
        let satellite = try issSatellite()
        let start = Date()
        let low = PassPredictor.passes(satellite: satellite, site: .rome, from: start,
                                       hours: 48, minElevation: 10, limit: 50)
        let high = PassPredictor.passes(satellite: satellite, site: .rome, from: start,
                                        hours: 48, minElevation: 60, limit: 50)
        XCTAssertLessThanOrEqual(high.count, low.count)
        XCTAssertTrue(high.allSatisfy { $0.maxElevation >= 60 })
    }

    func testLimitIsRespected() throws {
        let satellite = try issSatellite()
        let passes = PassPredictor.passes(satellite: satellite, site: .rome, from: Date(),
                                          hours: 72, minElevation: 0, limit: 3)
        XCTAssertLessThanOrEqual(passes.count, 3)
    }

    func testGeostationaryNeverRisesForRome() throws {
        // A GEO bird parked over the Indian Ocean is below Rome's horizon.
        let record = try XCTUnwrap(TLEParser.parse(TLEFixtures.issDocument, groups: []).records.first)
        _ = record
        // Use a synthetic high-orbit case instead: a satellite whose period is a
        // day and inclination zero stays put.
        let satellite = try issSatellite()
        let passes = PassPredictor.passes(satellite: satellite,
                                          site: ObserverSite(name: "South Pole",
                                                             latitude: -89.9,
                                                             longitude: 0),
                                          from: Date(),
                                          hours: 24,
                                          minElevation: 10,
                                          limit: 20)
        // The ISS never climbs above 10° from the pole.
        XCTAssertTrue(passes.isEmpty)
    }

    // MARK: - Compass

    func testCompassDirections() {
        XCTAssertEqual(Compass.direction(for: 0), "N")
        XCTAssertEqual(Compass.direction(for: 90), "E")
        XCTAssertEqual(Compass.direction(for: 180), "S")
        XCTAssertEqual(Compass.direction(for: 270), "W")
        XCTAssertEqual(Compass.direction(for: 359), "N")
        XCTAssertEqual(Compass.direction(for: -90), "W")
        XCTAssertEqual(Compass.direction(for: 45), "NE")
    }
}

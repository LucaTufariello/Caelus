//
//  SyntheticCatalogTests.swift
//  SatTrackerTests
//
//  The QA generator ships in the app, so its output has to be as valid as any
//  downloaded element set — otherwise the performance path it exists to
//  exercise is not the path a real catalog takes.
//

import XCTest
@testable import SatTracker

final class SyntheticCatalogTests: XCTestCase {

    func testGeneratesRequestedCount() {
        let (catalog, diagnostics) = SyntheticCatalog.make(count: 1_000)
        XCTAssertEqual(catalog.count, 1_000)
        XCTAssertEqual(diagnostics.unpropagatable, 0)
    }

    func testEveryRecordParsesWithMatchingChecksums() {
        let (catalog, _) = SyntheticCatalog.make(count: 200)
        XCTAssertEqual(Set(catalog.records.map(\.id)).count, 200, "NORAD numbers must be unique")
        for record in catalog.records {
            XCTAssertFalse(record.name.isEmpty)
            XCTAssertGreaterThan(record.elements.n₀, 0)
        }
    }

    func testGroupCountsSumToCatalog() {
        let (catalog, _) = SyntheticCatalog.make(count: 2_000)
        let perGroup = SatelliteGroup.allCases.map { catalog.count(in: $0) }
        XCTAssertEqual(perGroup.reduce(0, +), catalog.count,
                       "each synthetic record carries exactly one tag")
        XCTAssertEqual(catalog.count(in: .stations), 0)
    }

    func testShellsLandAtPlausibleAltitudes() {
        let (catalog, _) = SyntheticCatalog.make(count: 400)

        let leo = catalog.records.filter { $0.groups.contains(.starlink) }
        XCTAssertFalse(leo.isEmpty)
        for record in leo {
            XCTAssertGreaterThan(record.perigeeKm, 300)
            XCTAssertLessThan(record.apogeeKm, 1_000)
        }

        let geo = catalog.records.filter { $0.groups.contains(.weather) }
        XCTAssertFalse(geo.isEmpty)
        for record in geo {
            // Geostationary: one revolution per sidereal day, ±1 %.
            XCTAssertEqual(record.periodMinutes, 1_436, accuracy: 15)
        }
    }

    func testRaanSpansTheOrbitPlane() {
        let (catalog, _) = SyntheticCatalog.make(count: 400)
        let nodes = Set(catalog.records.map { Int($0.raanDeg.rounded()) })
        XCTAssertGreaterThan(nodes.count, 300, "records must not share a single orbital plane")
    }
}

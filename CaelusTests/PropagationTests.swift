//
//  PropagationTests.swift
//  CaelusTests
//
//  Sanity checks on the SGP4 pipeline, plus the performance gate the app's
//  budget depends on: a full 16 000-object tick under 250 ms.
//

import XCTest
import simd
import SatelliteKit
@testable import Caelus

final class PropagationTests: XCTestCase {

    private func records(_ text: String) -> [SatelliteRecord] {
        TLEParser.parse(text, groups: []).records
    }

    // MARK: - Single object

    /// SatelliteKit reports longitude in 0…360; the UI and every formatter
    /// expect −180…180. Sample a whole orbit so the wrap is exercised whatever
    /// time the suite happens to run.
    func testLongitudeIsAlwaysWrapped() async throws {
        let engine = PropagationEngine()
        await engine.load(records(TLEFixtures.issDocument))

        let start = Date()
        for step in 0..<24 {
            let date = start.addingTimeInterval(Double(step) * 300)
            let state = await engine.state(at: 0, date: date, site: .rome)
            let unwrapped = try XCTUnwrap(state)
            XCTAssertGreaterThanOrEqual(unwrapped.longitude, -180, "step \(step)")
            XCTAssertLessThanOrEqual(unwrapped.longitude, 180, "step \(step)")
        }

        let samples = await engine.trackSamples(at: 0, date: start,
                                                halfSpanMinutes: 95, stepSeconds: 60)
        XCTAssertFalse(samples.isEmpty)
        for sample in samples {
            XCTAssertGreaterThanOrEqual(sample.longitude, -180)
            XCTAssertLessThanOrEqual(sample.longitude, 180)
        }
    }

    func testISSPropagatesToAPlausibleOrbit() async throws {
        let engine = PropagationEngine()
        await engine.load(records(TLEFixtures.issDocument))

        let snapshot = await engine.tick(at: Date())
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertTrue(snapshot.valid[0])
        XCTAssertEqual(snapshot.failures, 0)

        let radius = Double(simd_length(snapshot.positions[0]))
        let altitude = (radius - 1) * GeoMath.earthRadiusKm
        // The ISS orbits between roughly 400 and 430 km.
        XCTAssertGreaterThan(altitude, 380)
        XCTAssertLessThan(altitude, 460)
    }

    func testISSStateReportsVelocityAndPosition() async throws {
        let engine = PropagationEngine()
        await engine.load(records(TLEFixtures.issDocument))

        let state = await engine.state(at: 0, date: Date(), site: .rome)
        let unwrapped = try XCTUnwrap(state)
        // Orbital velocity at ISS altitude is about 7.66 km/s.
        XCTAssertEqual(unwrapped.velocityKmS, 7.66, accuracy: 0.15)
        XCTAssertLessThanOrEqual(abs(unwrapped.latitude), 52)
        XCTAssertGreaterThanOrEqual(unwrapped.longitude, -180)
        XCTAssertLessThanOrEqual(unwrapped.longitude, 180)
        XCTAssertEqual((Double(simd_length(unwrapped.position)) - 1) * GeoMath.earthRadiusKm,
                       unwrapped.altitudeKm, accuracy: 1)
    }

    func testObserverGeometryIsConsistent() async throws {
        let engine = PropagationEngine()
        await engine.load(records(TLEFixtures.issDocument))

        let state = await engine.state(at: 0, date: Date(), site: .rome)
        let unwrapped = try XCTUnwrap(state)
        let range = try XCTUnwrap(unwrapped.rangeToObserverKm)
        let elevation = try XCTUnwrap(unwrapped.elevationFromObserver)
        let azimuth = try XCTUnwrap(unwrapped.azimuthFromObserver)

        // Range is bounded by the horizon distance and the antipode.
        XCTAssertGreaterThan(range, 300)
        XCTAssertLessThan(range, 20_000)
        XCTAssertGreaterThanOrEqual(elevation, -90)
        XCTAssertLessThanOrEqual(elevation, 90)
        XCTAssertGreaterThanOrEqual(azimuth, 0)
        XCTAssertLessThan(azimuth, 360)
    }

    func testPositionMovesOverTime() async throws {
        let engine = PropagationEngine()
        await engine.load(records(TLEFixtures.issDocument))

        let start = Date()
        let first = await engine.tick(at: start)
        let later = await engine.tick(at: start.addingTimeInterval(60))

        let moved = simd_distance(first.positions[0], later.positions[0])
        // About one degree of arc per 60 s, i.e. roughly 0.02 scene units.
        XCTAssertGreaterThan(moved, 0.005)
        XCTAssertLessThan(moved, 0.1)
    }

    func testEmptyCatalogIsHarmless() async {
        let engine = PropagationEngine()
        await engine.load([])
        let snapshot = await engine.tick(at: Date())
        XCTAssertEqual(snapshot.count, 0)
        XCTAssertEqual(snapshot.failures, 0)
    }

    func testStateForOutOfRangeIndexIsNil() async {
        let engine = PropagationEngine()
        await engine.load(records(TLEFixtures.issDocument))
        let state = await engine.state(at: 99, date: Date(), site: .rome)
        XCTAssertNil(state)
    }

    // MARK: - Batch

    func testSyntheticCatalogPropagatesCompletely() async {
        let engine = PropagationEngine()
        let catalog = records(TLEFixtures.syntheticDocument(count: 2_000))
        await engine.load(catalog)

        let snapshot = await engine.tick(at: Date())
        XCTAssertEqual(snapshot.count, 2_000)
        XCTAssertEqual(snapshot.valid.filter { $0 }.count, 2_000)
        XCTAssertEqual(snapshot.failures, 0)
    }

    func testSnapshotIsInCatalogOrder() async throws {
        let engine = PropagationEngine()
        let catalog = records(TLEFixtures.syntheticDocument(count: 200))
        await engine.load(catalog)

        let snapshot = await engine.tick(at: Date())
        for index in [0, 37, 199] {
            let state = await engine.state(at: index, date: snapshot.time, site: nil)
            let expected = try XCTUnwrap(state)
            XCTAssertEqual(snapshot.positions[index], expected.position)
        }
    }

    // MARK: - Performance gate

    /// The spec's budget: 16 000 objects propagated in under 250 ms per tick.
    func testPerformance() async throws {
        let engine = PropagationEngine()
        let catalog = records(TLEFixtures.syntheticDocument(count: 16_000))
        XCTAssertEqual(catalog.count, 16_000, "fixture failed to build a full catalog")

        await engine.load(catalog)

        // Warm the propagators so the measurement is steady-state.
        _ = await engine.tick(at: Date())

        var samples: [TimeInterval] = []
        for step in 0..<3 {
            let snapshot = await engine.tick(at: Date().addingTimeInterval(Double(step)))
            XCTAssertEqual(snapshot.valid.filter { $0 }.count, 16_000)
            samples.append(snapshot.duration)
        }

        let median = samples.sorted()[samples.count / 2]
        print("SGP4 16k tick: \(samples.map { String(format: "%.1f ms", $0 * 1000) }.joined(separator: ", "))")
        XCTAssertLessThan(median, 0.250, "16k propagation exceeded the 250 ms budget")
    }
}

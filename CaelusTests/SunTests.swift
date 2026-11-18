//
//  SunTests.swift
//  CaelusTests
//

import XCTest
import simd
import SatelliteKit
@testable import Caelus

final class SunTests: XCTestCase {

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // MARK: - Subsolar point

    func testSubsolarLatitudeStaysWithinTheTropics() {
        for day in stride(from: 0, to: 365, by: 11) {
            let date = utc(2026, 1, 1).addingTimeInterval(Double(day) * 86_400)
            let point = SunCalculator.subsolarPoint(at: date)
            XCTAssertLessThanOrEqual(abs(point.lat), 23.6, "day \(day)")
        }
    }

    func testSubsolarLatitudeAtSolstices() {
        // June solstice: the Sun stands over the Tropic of Cancer.
        let june = SunCalculator.subsolarPoint(at: utc(2026, 6, 21, 12))
        XCTAssertEqual(june.lat, 23.4, accuracy: 0.6)

        // December solstice: over the Tropic of Capricorn.
        let december = SunCalculator.subsolarPoint(at: utc(2026, 12, 21, 12))
        XCTAssertEqual(december.lat, -23.4, accuracy: 0.6)
    }

    func testSubsolarLongitudeMovesWestThroughTheDay() {
        let noon = SunCalculator.subsolarPoint(at: utc(2026, 3, 20, 12))
        let later = SunCalculator.subsolarPoint(at: utc(2026, 3, 20, 15))
        // Three hours later the Sun is 45° further west.
        let delta = GeoMath.wrapLongitude(later.lon - noon.lon)
        XCTAssertEqual(delta, -45, accuracy: 1.5)
    }

    // MARK: - Scene direction

    func testSceneDirectionIsUnitLength() {
        for hour in stride(from: 0, to: 24, by: 3) {
            let direction = SunCalculator.sceneDirection(at: utc(2026, 5, 4, hour))
            XCTAssertEqual(simd_length(direction), 1, accuracy: 1e-5)
        }
    }

    func testSceneDirectionMatchesSubsolarPoint() {
        let date = utc(2026, 8, 12, 9)
        let point = SunCalculator.subsolarPoint(at: date)
        let direction = SunCalculator.sceneDirection(at: date)
        let expected = GeoMath.unitVector(lat: point.lat, lon: point.lon)

        XCTAssertEqual(direction.x, expected.x, accuracy: 1e-4)
        XCTAssertEqual(direction.y, expected.y, accuracy: 1e-4)
        XCTAssertEqual(direction.z, expected.z, accuracy: 1e-4)
    }

    // MARK: - Observer daylight

    func testRomeIsDarkAtLocalMidnight() {
        // Rome is UTC+2 in summer; 22:00 UTC is midnight local.
        XCTAssertTrue(SunCalculator.isObserverDark(at: utc(2026, 7, 15, 22), site: .rome))
    }

    func testRomeIsLitAtLocalNoon() {
        XCTAssertFalse(SunCalculator.isObserverDark(at: utc(2026, 7, 15, 10), site: .rome))
    }

    func testSunElevationIsHigherInSummer() {
        let summer = SunCalculator.elevationDeg(at: utc(2026, 6, 21, 11), site: .rome)
        let winter = SunCalculator.elevationDeg(at: utc(2026, 12, 21, 11), site: .rome)
        XCTAssertGreaterThan(summer, winter)
        XCTAssertGreaterThan(summer, 60)
    }

    func testSunElevationAtNightIsNegative() {
        XCTAssertLessThan(SunCalculator.elevationDeg(at: utc(2026, 3, 1, 0), site: .rome), 0)
    }

    // MARK: - Satellite illumination

    func testSatelliteOnTheDaySideIsSunlit() {
        let date = utc(2026, 4, 1, 12)
        let sun = SunCalculator.sunUnitECI(julianDays: date.julianDate)
        let onDaySide = Vector(sun.x * 7_000, sun.y * 7_000, sun.z * 7_000)
        XCTAssertTrue(SunCalculator.isSunlit(satelliteECI: onDaySide, sunUnit: sun))
    }

    func testSatelliteBehindTheEarthIsInEclipse() {
        let date = utc(2026, 4, 1, 12)
        let sun = SunCalculator.sunUnitECI(julianDays: date.julianDate)
        let behind = Vector(-sun.x * 7_000, -sun.y * 7_000, -sun.z * 7_000)
        XCTAssertFalse(SunCalculator.isSunlit(satelliteECI: behind, sunUnit: sun))
    }
}

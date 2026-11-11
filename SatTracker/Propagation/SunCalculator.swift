//
//  SunCalculator.swift
//  SatTracker
//
//  Solar geometry: the subsolar point drives the globe's terminator, and the
//  same numbers decide whether a satellite is sunlit and whether the observer
//  is in darkness — the two conditions behind the "naked eye" pass hint.
//

import Foundation
import SatelliteKit
import simd

enum SunCalculator {

    /// Astronomical unit in kilometres; only used to place the Sun far enough
    /// away that topocentric parallax is negligible.
    static let sunDistanceKm: Double = 149_597_870.7

    /// Civil twilight: the observer is dark enough to see a sunlit satellite.
    static let observerDarkElevation: Double = -6

    // MARK: - Solar position

    /// Unit vector toward the Sun in the inertial frame.
    static func sunUnitECI(julianDays: Double) -> Vector {
        solarCel(julianDays: julianDays)
    }

    /// Geodetic coordinates of the point where the Sun is overhead.
    ///
    /// `eci2geo` applies an oblate-spheroid correction measured in kilometres,
    /// so the celestial vector must be in kilometres too — handing it a unit
    /// vector lets the correction term swamp the real declination.
    static func subsolarPoint(julianDays: Double) -> LatLonAlt {
        let unit = solarCel(julianDays: julianDays)
        let celestial = Vector(unit.x * sunDistanceKm,
                               unit.y * sunDistanceKm,
                               unit.z * sunDistanceKm)
        return eci2geo(julianDays: julianDays, celestial: celestial)
    }

    static func subsolarPoint(at date: Date) -> LatLonAlt {
        subsolarPoint(julianDays: date.julianDate)
    }

    /// Direction toward the Sun in the Earth-fixed scene frame.
    static func sceneDirection(at date: Date) -> SIMD3<Float> {
        let point = subsolarPoint(at: date)
        return GeoMath.unitVector(lat: point.lat, lon: point.lon)
    }

    // MARK: - Observer

    /// Solar elevation above the observer's horizon, in degrees.
    static func elevationDeg(at date: Date, site: ObserverSite) -> Double {
        let julian = date.julianDate
        let unit = solarCel(julianDays: julian)
        let sun = Vector(unit.x * sunDistanceKm, unit.y * sunDistanceKm, unit.z * sunDistanceKm)
        return topPosition(julianDays: julian, satCel: sun, obsLLA: site.latLonAlt).elev
    }

    /// True when the observer is in (civil) darkness.
    static func isObserverDark(at date: Date, site: ObserverSite) -> Bool {
        elevationDeg(at: date, site: site) < observerDarkElevation
    }

    // MARK: - Illumination

    /// Cylindrical Earth-shadow model.
    ///
    /// A satellite is eclipsed when it lies on the far side of the planet from
    /// the Sun and within one Earth radius of the shadow axis. The cylindrical
    /// approximation is accurate to a few seconds of entry/exit time, which is
    /// far below what the UI reports.
    static func isSunlit(satelliteECI: Vector, sunUnit: Vector) -> Bool {
        let along = satelliteECI.x * sunUnit.x
            + satelliteECI.y * sunUnit.y
            + satelliteECI.z * sunUnit.z
        if along > 0 { return true }          // sunward hemisphere: always lit

        let px = satelliteECI.x - along * sunUnit.x
        let py = satelliteECI.y - along * sunUnit.y
        let pz = satelliteECI.z - along * sunUnit.z
        let perpendicular = (px * px + py * py + pz * pz).squareRoot()

        return perpendicular > EarthConstants.Rₑ
    }

    static func isSunlit(satelliteECI: Vector, at date: Date) -> Bool {
        isSunlit(satelliteECI: satelliteECI, sunUnit: sunUnitECI(julianDays: date.julianDate))
    }

    // MARK: - Twilight bands

    /// A short label for the observer's current light level.
    static func lightLevel(at date: Date, site: ObserverSite) -> String {
        let elevation = elevationDeg(at: date, site: site)
        switch elevation {
        case 0...: return "Daylight"
        case -6..<0: return "Civil twilight"
        case -12..<(-6): return "Nautical twilight"
        case -18..<(-12): return "Astronomical twilight"
        default: return "Night"
        }
    }
}

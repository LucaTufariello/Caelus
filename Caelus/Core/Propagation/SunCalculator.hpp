// SunCalculator.hpp — solar geometry.
//
// Translated from the Swift app's Propagation/SunCalculator.swift. The subsolar
// point drives the globe's terminator, and the same numbers decide whether a
// satellite is sunlit and whether the observer is in darkness — the two
// conditions behind the "naked eye" pass hint.

#pragma once

#include <string>

#include "../Data/Models.hpp"
#include "../Geo/GeoMath.hpp"
#include "../Sky/Astro.hpp"

namespace caelus {

class SunCalculator {
public:
    // Astronomical unit in kilometres; only used to place the Sun far enough
    // away that topocentric parallax is negligible.
    static constexpr double sunDistanceKm = 149597870.7;

    // Civil twilight: the observer is dark enough to see a sunlit satellite.
    static constexpr double observerDarkElevation = -6.0;

    // MARK: - Solar position

    // Unit vector toward the Sun in the inertial frame.
    static sky::Vec3 sunUnitECI(double julianDays) { return sky::solarCel(julianDays); }

    // Geodetic coordinates of the point where the Sun is overhead.
    static sky::LatLonAlt subsolarPoint(double julianDays);

    static sky::LatLonAlt subsolarPointAt(Date date) {
        return subsolarPoint(sky::julianFromDate(date));
    }

    // Direction toward the Sun in the Earth-fixed scene frame.
    static sky::Vec3 sceneDirection(Date date);

    // MARK: - Observer

    // Solar elevation above the observer's horizon, in degrees.
    static double elevationDeg(Date date, const ObserverSite& site);

    // True when the observer is in (civil) darkness.
    static bool isObserverDark(Date date, const ObserverSite& site) {
        return elevationDeg(date, site) < observerDarkElevation;
    }

    // MARK: - Illumination

    // Cylindrical Earth-shadow model.
    static bool isSunlit(const sky::Vec3& satelliteECI, const sky::Vec3& sunUnit);

    static bool isSunlit(const sky::Vec3& satelliteECI, Date date) {
        return isSunlit(satelliteECI, sunUnitECI(sky::julianFromDate(date)));
    }

    // MARK: - Twilight bands

    // A short label for the observer's current light level.
    static std::string lightLevel(Date date, const ObserverSite& site);
};

}  // namespace caelus

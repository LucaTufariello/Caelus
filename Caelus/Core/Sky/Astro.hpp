// Astro.hpp — Earth constants, sidereal time, solar position and frame conversions.

#pragma once

#include "MathUtil.hpp"
#include "TimeUtil.hpp"

namespace caelus::sky {

struct EarthConstants {
    static constexpr double R_e = 6378.135;              // Earth radius (km), WGS72
    static constexpr double rotation_e = 1.00273790934;  // sidereal rotations per UT day

    static constexpr double flattening_e = 1.0 / 298.26;
    static constexpr double e2 = flattening_e * (2.0 - flattening_e);

    static constexpr double mu_e = 398600.8;  // gravitational constant (km³/s²)
    static const double k_e;                  // √(GM) in (Earth radii)^1.5/min

    static constexpr double J2 = +1.082616e-3;
    static constexpr double K2 = 0.5 * J2;

    static constexpr double J3 = -2.53881e-6;
    static constexpr double J3OVK2 = -J3 / K2;

    static constexpr double J4 = -1.65597e-6;
    static constexpr double K4 = -0.375 * J4;
};

struct LatLonAlt {
    double lat = 0.0;  // degrees
    double lon = 0.0;  // degrees
    double alt = 0.0;  // km above the geoid
};

struct AziEleDst {
    double azim = 0.0;  // degrees
    double elev = 0.0;  // degrees
    double dist = 0.0;  // km
};

// Greenwich mean sidereal time in degrees (IAU 1982 GMST-UT1 model).
double zeroMeanSiderealTime(double julianDate);

inline double siteMeanSiderealTime(double julianDate, double siteLongitude) {
    return std::fmod(zeroMeanSiderealTime(julianDate) + siteLongitude + 360.0, 360.0);
}

// The Sun's position in the ECI frame, as a unit vector.
Vec3 solarCel(double julianDays);

// Geodetic position of an ECI point on the oblate Earth.
LatLonAlt eci2geo(double julianDays, const Vec3& celestial);

// ECI of a geodetic point, rotated by sidereal time.
Vec3 geo2eci(double julianDays, const LatLonAlt& geodetic);

// ECI of a geodetic point without the sidereal rotation.
Vec3 geo2eciStatic(const LatLonAlt& geodetic);

// Observer-frame vector from observer to target.
Vec3 cel2top(double julianDays, const Vec3& satCel, const Vec3& obsCel);

// Azimuth, elevation and range of a satellite from an observer.
AziEleDst topPosition(double julianDays, const Vec3& satCel, const LatLonAlt& obsLLA);

}  // namespace caelus::sky

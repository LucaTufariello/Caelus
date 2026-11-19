#include "Astro.hpp"

namespace caelus::sky {

const double EarthConstants::k_e =
    60.0 / std::sqrt(EarthConstants::R_e * EarthConstants::R_e * EarthConstants::R_e /
                    EarthConstants::mu_e);

double zeroMeanSiderealTime(double julianDate) {
    const double fractionalDay = std::fmod(julianDate + 0.5, 1.0);
    const double adjustedJD = julianDate - fractionalDay;
    const double timespanCenturies = (adjustedJD - kJulianEpoch2000) / kDaysPerCentury;

    double greenwichSiderealSeconds =
        24110.54841 +
        timespanCenturies * (8640184.812866 +
                             timespanCenturies * (0.093104 - timespanCenturies * 0.0000062));

    greenwichSiderealSeconds =
        std::fmod(greenwichSiderealSeconds +
                      fractionalDay * EarthConstants::rotation_e * kDay2Seconds,
                  kDay2Seconds);

    return std::fmod((360.0 * greenwichSiderealSeconds * kSecond2Day) + 360.0, 360.0);
}

Vec3 solarCel(double julianDays) {
    const double daysSinceJD2000 = julianDays - kJulianEpoch2000;

    const double eclipticInclin = (23.439 - 0.00000036 * daysSinceJD2000) * deg2rad;
    const double solarMeanAnom = (357.529 + 0.98560028 * daysSinceJD2000) * deg2rad;
    const double aberration = 1.915 * std::sin(solarMeanAnom) + 0.020 * std::sin(2.0 * solarMeanAnom);
    const double solarEclpLong =
        ((280.459 + 0.98564736 * daysSinceJD2000) + aberration) * deg2rad;

    return {std::cos(solarEclpLong), std::sin(solarEclpLong) * std::cos(eclipticInclin),
            std::sin(solarEclpLong) * std::sin(eclipticInclin)};
}

LatLonAlt eci2geo(double julianDays, const Vec3& celestial) {
    const double positionXY = std::sqrt(celestial.x * celestial.x + celestial.y * celestial.y);
    double newLatRads = std::atan2(celestial.z, positionXY);

    double oldLatRads = 0.0;
    double correction = 0.0;

    do {
        const double sinLatitude = std::sin(newLatRads);
        correction = EarthConstants::R_e /
                     std::sqrt(1.0 - EarthConstants::e2 * sinLatitude * sinLatitude);
        oldLatRads = newLatRads;
        newLatRads = std::atan2(celestial.z + correction * EarthConstants::e2 * sinLatitude,
                                positionXY);
    } while (std::fabs(newLatRads - oldLatRads) > 0.0001);

    const double sidereal = (julianDays < 0.0) ? 0.0 : zeroMeanSiderealTime(julianDays);

    return {newLatRads * rad2deg,
            std::fmod(360.0 + atan2pi(celestial.y, celestial.x) * rad2deg - sidereal, 360.0),
            positionXY / std::cos(newLatRads) - correction};
}

Vec3 geo2eciStatic(const LatLonAlt& geodetic) {
    const double latitudeRads = geodetic.lat * deg2rad;
    const double sinLatitude = std::sin(latitudeRads);
    const double cosLatitude = std::cos(latitudeRads);

    const double siderealRads = geodetic.lon * deg2rad;
    const double sinSidereal = std::sin(siderealRads);
    const double cosSidereal = std::cos(siderealRads);

    const double correction = EarthConstants::R_e /
                              std::sqrt(1.0 + EarthConstants::e2 * sinLatitude * sinLatitude);
    const double s = (1.0 - EarthConstants::e2) * correction;
    const double achcp = (correction + geodetic.alt) * cosLatitude;

    return {achcp * cosSidereal, achcp * sinSidereal, (geodetic.alt + s) * sinLatitude};
}

Vec3 geo2eci(double julianDays, const LatLonAlt& geodetic) {
    const double latitudeRads = geodetic.lat * deg2rad;
    const double sinLatitude = std::sin(latitudeRads);
    const double cosLatitude = std::cos(latitudeRads);

    const double siderealRads = siteMeanSiderealTime(julianDays, geodetic.lon) * deg2rad;
    const double sinSidereal = std::sin(siderealRads);
    const double cosSidereal = std::cos(siderealRads);

    const double correction = EarthConstants::R_e /
                              std::sqrt(1.0 + EarthConstants::e2 * sinLatitude * sinLatitude);
    const double s = (1.0 - EarthConstants::e2) * correction;
    const double achcp = (correction + geodetic.alt) * cosLatitude;

    return {achcp * cosSidereal, achcp * sinSidereal, (geodetic.alt + s) * sinLatitude};
}

Vec3 cel2top(double julianDays, const Vec3& satCel, const Vec3& obsCel) {
    const LatLonAlt obsLLA = eci2geo(julianDays, obsCel);

    const double latitudeRads = obsLLA.lat * deg2rad;
    const double sinLatitude = std::sin(latitudeRads);
    const double cosLatitude = std::cos(latitudeRads);

    const double siderealRads = siteMeanSiderealTime(julianDays, obsLLA.lon) * deg2rad;
    const double sinSidereal = std::sin(siderealRads);
    const double cosSidereal = std::cos(siderealRads);

    const Vec3 obsCelRecovered = geo2eci(julianDays, obsLLA);
    const Vec3 obs2sat = satCel - obsCelRecovered;

    return {obs2sat.x * (+sinLatitude * cosSidereal) + obs2sat.y * (+sinLatitude * sinSidereal) +
                obs2sat.z * (-cosLatitude),
            obs2sat.x * (-sinSidereal) + obs2sat.y * (+cosSidereal) + obs2sat.z * 0.0,
            obs2sat.x * (+cosLatitude * cosSidereal) + obs2sat.y * (+cosLatitude * sinSidereal) +
                obs2sat.z * (+sinLatitude)};
}

AziEleDst topPosition(double julianDays, const Vec3& satCel, const LatLonAlt& obsLLA) {
    const Vec3 obsCel = geo2eci(julianDays, obsLLA);  // ECI
    const Vec3 top = cel2top(julianDays, satCel, obsCel);
    const double d = (obsCel - satCel).magnitude();

    return {atan2pi(top.y, -top.x) * rad2deg, std::asin(top.z / d) * rad2deg, d};
}

}  // namespace caelus::sky

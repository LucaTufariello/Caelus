#include "SunCalculator.hpp"

#include <cmath>

namespace caelus {

using sky::Vec3;

sky::LatLonAlt SunCalculator::subsolarPoint(double julianDays) {
    const Vec3 unit = sky::solarCel(julianDays);
    // eci2geo applies an oblate-spheroid correction measured in kilometres, so
    // the celestial vector must be in kilometres too.
    const Vec3 celestial{unit.x * sunDistanceKm, unit.y * sunDistanceKm,
                         unit.z * sunDistanceKm};
    return sky::eci2geo(julianDays, celestial);
}

Vec3 SunCalculator::sceneDirection(Date date) {
    const sky::LatLonAlt point = subsolarPointAt(date);
    return GeoMath::unitVector(point.lat, point.lon);
}

double SunCalculator::elevationDeg(Date date, const ObserverSite& site) {
    const double julian = sky::julianFromDate(date);
    const Vec3 unit = sky::solarCel(julian);
    const Vec3 sun{unit.x * sunDistanceKm, unit.y * sunDistanceKm, unit.z * sunDistanceKm};
    return sky::topPosition(julian, sun, site.latLonAlt()).elev;
}

bool SunCalculator::isSunlit(const Vec3& satelliteECI, const Vec3& sunUnit) {
    const double along = satelliteECI.x * sunUnit.x + satelliteECI.y * sunUnit.y +
                         satelliteECI.z * sunUnit.z;
    if (along > 0.0) return true;  // sunward hemisphere: always lit

    const double px = satelliteECI.x - along * sunUnit.x;
    const double py = satelliteECI.y - along * sunUnit.y;
    const double pz = satelliteECI.z - along * sunUnit.z;
    const double perpendicular = std::sqrt(px * px + py * py + pz * pz);

    return perpendicular > sky::EarthConstants::R_e;
}

std::string SunCalculator::lightLevel(Date date, const ObserverSite& site) {
    const double elevation = elevationDeg(date, site);
    if (elevation >= 0.0) return "Daylight";
    if (elevation >= -6.0) return "Civil twilight";
    if (elevation >= -12.0) return "Nautical twilight";
    if (elevation >= -18.0) return "Astronomical twilight";
    return "Night";
}

}  // namespace caelus

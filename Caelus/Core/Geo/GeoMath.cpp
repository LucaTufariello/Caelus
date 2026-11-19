#include "GeoMath.hpp"

#include <algorithm>
#include <cmath>

namespace caelus {

using sky::Vec3;

Vec3 GeoMath::unitVector(double lat, double lon) {
    const double latR = lat * sky::kPi / 180.0;
    const double lonR = (lon + longitudeOffset) * sky::kPi / 180.0;
    const double c = std::cos(latR);
    return {c * std::cos(lonR), std::sin(latR), -c * std::sin(lonR)};
}

Vec3 GeoMath::scenePosition(double lat, double lon, double altKm) {
    const double r = 1.0 + altKm / earthRadiusKm();
    return scenePositionOnRadius(lat, lon, r);
}

Vec3 GeoMath::scenePositionOnRadius(double lat, double lon, double radius) {
    const Vec3 unit = unitVector(lat, lon);
    return {unit.x * radius, unit.y * radius, unit.z * radius};
}

std::pair<double, double> GeoMath::latLon(const Vec3& unit) {
    const Vec3 n = sky::normalize(unit);
    const double lat = std::asin(std::max(-1.0, std::min(1.0, n.y))) * 180.0 / sky::kPi;
    const double lon = std::atan2(-n.z, n.x) * 180.0 / sky::kPi;
    return {lat, lon};
}

std::vector<std::vector<sky::LatLonAlt>> GeoMath::splitAtAntimeridian(
    const std::vector<sky::LatLonAlt>& points) {
    if (points.empty()) return {};

    std::vector<std::vector<sky::LatLonAlt>> runs;
    std::vector<sky::LatLonAlt> current;
    current.push_back(points[0]);

    for (size_t index = 1; index < points.size(); ++index) {
        const sky::LatLonAlt& point = points[index];
        const sky::LatLonAlt& previous = current.back();
        if (std::fabs(point.lon - previous.lon) > 180.0) {
            runs.push_back(current);
            current = {point};
        } else {
            current.push_back(point);
        }
    }
    runs.push_back(current);

    std::vector<std::vector<sky::LatLonAlt>> filtered;
    filtered.reserve(runs.size());
    for (auto& run : runs) {
        if (run.size() > 1) filtered.push_back(std::move(run));
    }
    return filtered;
}

double GeoMath::greatCircleKm(double lat1, double lon1, double lat2, double lon2) {
    const double phi1 = lat1 * sky::kPi / 180.0;
    const double phi2 = lat2 * sky::kPi / 180.0;
    const double deltaPhi = (lat2 - lat1) * sky::kPi / 180.0;
    const double deltaLambda = (lon2 - lon1) * sky::kPi / 180.0;
    const double a = std::sin(deltaPhi / 2.0) * std::sin(deltaPhi / 2.0) +
                     std::cos(phi1) * std::cos(phi2) * std::sin(deltaLambda / 2.0) *
                         std::sin(deltaLambda / 2.0);
    return 2.0 * earthRadiusKm() * std::atan2(std::sqrt(a), std::sqrt(1.0 - a));
}

double GeoMath::wrapLongitude(double lon) {
    double value = std::fmod(lon, 360.0);  // Swift's truncatingRemainder
    if (value >= 180.0) value -= 360.0;
    if (value < -180.0) value += 360.0;
    return value;
}

Vec3 GeoMath::slerp(const Vec3& a, const Vec3& b, double t) {
    const double ra = a.magnitude();
    const double rb = b.magnitude();
    if (!(ra > 0.0) || !(rb > 0.0)) return a;

    const Vec3 na{a.x / ra, a.y / ra, a.z / ra};
    const Vec3 nb{b.x / rb, b.y / rb, b.z / rb};
    const double dot = std::max(-1.0, std::min(1.0, sky::dotProduct(na, nb)));
    const double omega = std::acos(dot);
    const double r = ra + (rb - ra) * t;

    if (omega < 1e-4) {
        return {(na.x + (nb.x - na.x) * t) * r, (na.y + (nb.y - na.y) * t) * r,
                (na.z + (nb.z - na.z) * t) * r};
    }

    const double s = std::sin(omega);
    const double wa = std::sin((1.0 - t) * omega) / s;
    const double wb = std::sin(t * omega) / s;
    return {(na.x * wa + nb.x * wb) * r, (na.y * wa + nb.y * wb) * r,
            (na.z * wa + nb.z * wb) * r};
}

}  // namespace caelus

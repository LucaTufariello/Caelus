#include "Satellite.hpp"

#include <cmath>

namespace caelus::sky {

Satellite::Satellite(const Elements& elements)
    : tle_(elements), deepProp_(elements) {
    // `commonName` falls back to the international designator when the element
    // set arrived without a name line, exactly as SatelliteKit does.
    commonName_ = tle_.commonName.empty() ? tle_.launchName : tle_.commonName;
    noradIdent_ = std::to_string(tle_.noradIndex);

    if (isDeepSpace(tle_)) {
        deep_ = true;
    } else {
        sgp_.emplace(tle_);
    }
}

PVCoordinates Satellite::pvCoordinates(double minsAfterEpoch) const {
    if (deep_) return deepProp_.getPVCoordinates(minsAfterEpoch);
    return sgp_->getPVCoordinates(minsAfterEpoch);
}

Vec3 Satellite::position(double julianDays) const {
    const PVCoordinates pv = pvCoordinates(minsAfterEpoch(julianDays));
    return {pv.position.x / 1000.0, pv.position.y / 1000.0, pv.position.z / 1000.0};
}

Vec3 Satellite::velocity(double julianDays) const {
    const PVCoordinates pv = pvCoordinates(minsAfterEpoch(julianDays));
    return {pv.velocity.x / 1000.0, pv.velocity.y / 1000.0, pv.velocity.z / 1000.0};
}

LatLonAlt Satellite::geoPosition(double julianDays) const {
    return eci2geo(julianDays, position(julianDays));
}

AziEleDst Satellite::topPosition(double julianDays, const LatLonAlt& observer) const {
    const Vec3 satCel = position(julianDays);
    const Vec3 obsCel = geo2eci(julianDays, observer);
    const Vec3 top = cel2top(julianDays, satCel, obsCel);

    const double z = top.magnitude();

    return AziEleDst{atan2pi(top.y, -top.x) * rad2deg,
                     std::asin(top.z / z) * rad2deg,
                     z};
}

}  // namespace caelus::sky

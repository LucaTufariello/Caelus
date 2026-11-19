// Satellite.hpp — one object's propagator, chosen by orbital period.
//
// Ported from SatelliteKit, MIT licence, © 2017-25 Gavin Eadie.

#pragma once

#include <optional>
#include <string>

#include "Astro.hpp"
#include "Elements.hpp"
#include "Propagator.hpp"

namespace caelus::sky {

// A satellite is either near-Earth (SGP4) or deep-space (SDP4), decided once at
// construction; the choice is invisible to callers.
class Satellite {
public:
    explicit Satellite(const Elements& elements);

    const Elements& tle() const { return tle_; }
    const std::string& commonName() const { return commonName_; }
    const std::string& noradIdent() const { return noradIdent_; }
    double t0Days1950() const { return tle_.t0; }

    // Julian date of an offset (in minutes) from the element set's epoch.
    double julianDay(double minsAfterEpoch) const {
        return (tle_.t0 + kJulianEpoch1950) + minsAfterEpoch * kMinute2Day;
    }

    double minsAfterEpoch(double julianDays) const {
        return (julianDays - (tle_.t0 + kJulianEpoch1950)) * kDay2Minutes;
    }

    // Earth-centred inertial position (km) and velocity (km/s).
    Vec3 position(double julianDays) const;
    Vec3 velocity(double julianDays) const;

    // Geodetic position on the oblate Earth.
    LatLonAlt geoPosition(double julianDays) const;

    // Azimuth, elevation and range from a ground observer.
    AziEleDst topPosition(double julianDays, const LatLonAlt& observer) const;

    // Raw propagation at minutes from epoch (metres and metres/second).
    PVCoordinates pvCoordinates(double minsAfterEpoch) const;

private:
    Elements tle_;
    std::string commonName_;
    std::string noradIdent_;
    bool deep_ = false;
    std::optional<SGP4Propagator> sgp_;
    DeepSDP4Propagator deepProp_;
};

}  // namespace caelus::sky

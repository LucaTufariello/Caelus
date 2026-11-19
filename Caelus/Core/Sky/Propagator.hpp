// Propagator.hpp — SGP4 / DeepSDP4 orbit propagation.
//
// Ported from SatelliteKit, MIT licence, © 2017-25 Gavin Eadie; itself a translation of
// Vallado/Crawford/Hujsak/Kelso's reference SGP4 (AIAA 2006-6753). The arithmetic is kept
// identical so that a Caelus build reproduces the previous Swift build's positions.

#pragma once

#include "Elements.hpp"
#include "MathUtil.hpp"
#include "TimeUtil.hpp"

namespace caelus::sky {

struct PVCoordinates {
    Vec3 position;  // metres
    Vec3 velocity;  // metres/second
};

// Constants derived once from the element set.
struct PropagatorData {
    Elements tle;
    double perigee = 0.0;  // km

    double M_dot = 0.0;
    double w_dot = 0.0;
    double raan_dot = 0.0;
    double xnodcf = 0.0;

    double e0sq = 0.0;
    double beta0sq = 0.0;
    double beta0 = 0.0;

    double xi = 0.0;
    double eta = 0.0;
    double etasq = 0.0;
    double eeta = 0.0;

    double coef = 0.0;
    double coef1 = 0.0;

    double c1 = 0.0;
    double c2 = 0.0;
    double c4 = 0.0;
    double t2cof = 0.0;

    double sini0 = 0.0;
    double cosi0 = 0.0;
    double theta2 = 0.0;  // cos²(i₀)
    double s = 0.0;
};

// The slowly-varying orbital state between the secular and short-period corrections.
struct PropagatorState {
    double e = 0.0;
    double i = 0.0;
    double w = 0.0;
    double raan = 0.0;
    double a = 0.0;
    double xl = 0.0;
};

PropagatorData createPropagatorData(const Elements& tle);

// Position and velocity from a state; sini0/cosi0 are the values currently in force
// (the deep-space propagator replaces them with the perturbed inclination's sine/cosine).
PVCoordinates computePV(const PropagatorState& state, double sini0, double cosi0);

// Near-Earth propagator (period < 225 minutes).
class SGP4Propagator {
public:
    explicit SGP4Propagator(const Elements& tle);

    const Elements& tle() const { return data_.tle; }
    PVCoordinates getPVCoordinates(double minsAfterEpoch) const;
    double minsSinceEpoch(Date date) const {
        return (date - dateFromDays1950(data_.tle.t0)) / 60.0;
    }

private:
    void sxpPropagate(double minsAfterEpoch, PropagatorState& state) const;

    PropagatorData data_;
    double dM0Cubed_ = 0.0;
    double d2_ = 0.0;
    double d3_ = 0.0;
    double d4_ = 0.0;
    double t3cof_ = 0.0;
    double t4cof_ = 0.0;
    double t5cof_ = 0.0;
    double omgcof_ = 0.0;
    double xmcof_ = 0.0;
    double c5_ = 0.0;
};

// Deep-space propagator (period >= 225 minutes), including luni-solar and resonance terms.
class DeepSDP4Propagator {
public:
    explicit DeepSDP4Propagator(const Elements& tle) : tle_(tle) {}

    const Elements& tle() const { return tle_; }
    PVCoordinates getPVCoordinates(double minsAfterEpoch) const;

private:
    Elements tle_;
};

// Period >= 225 minutes is deep space (or an explicit ephemeris type selects one).
bool isDeepSpace(const Elements& tle);

}  // namespace caelus::sky

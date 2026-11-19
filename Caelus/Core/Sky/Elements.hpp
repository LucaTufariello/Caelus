// Elements.hpp — a parsed two-line element set.
//
// Ported from SatelliteKit, MIT licence, © 2017-25 Gavin Eadie.

#pragma once

#include <cstdint>
#include <stdexcept>
#include <string>

#include "MathUtil.hpp"

namespace caelus::sky {

struct TLEError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

struct SGPError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// A satellite element set. Angles are radians; mean motion is radians/minute and the
// semi-major axis is in Earth radii, both after the reverse-Kozai correction.
struct Elements {
    std::string commonName;    // line zero name, if any [eg. ISS (ZARYA)]
    uint32_t noradIndex = 0;   // satellite number [eg. 25544]
    std::string launchName;    // international designation [eg. 1998-067A]

    double t0 = 0.0;    // TLE epoch (days since 1950)
    double e0 = 0.0;    // eccentricity
    double i0 = 0.0;    // inclination (radians)
    double w0 = 0.0;    // argument of perigee (radians)
    double raan0 = 0.0; // right ascension of ascending node (radians)
    double M0 = 0.0;    // mean anomaly (radians)

    double n0 = 0.0;    // mean motion (radians/min), un-Kozai'd
    double a0 = 0.0;    // semi-major axis (Earth radii), un-Kozai'd

    int ephemType = 0;  // ephemeris type
    std::string tleClass;  // classification (U for unclassified)
    int tleNumber = 0;  // element number
    int revNumber = 0;  // revolution number at epoch

    double dragCoeff = 0.0;  // BSTAR drag term
    double n0Prime = 0.0;    // Kozai'd mean motion, kept for completeness

    // Build from the three lines of a three-line element set.
    static Elements parse(const std::string& line0, const std::string& line1,
                          const std::string& line2);
};

// Convert an Alpha-5 NORAD id ("B1234") to an integer.
uint32_t alpha5ID(const std::string& noradID);

}  // namespace caelus::sky

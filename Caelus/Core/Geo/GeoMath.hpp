// GeoMath.hpp — the single place where geographic coordinates become scene coordinates.
//
// Translated from the Swift app's Propagation/GeoMath.swift. The frame convention
// is the one every other layer depends on:
//
//     (lat 0°, lon 0°)    → (1, 0, 0)      equator / prime meridian
//     lat +90°            → (0, 1, 0)      north pole
//     (lat 0°, lon +90°)  → (0, 0, −1)     equator / 90° east
//
// so that
//
//     x =  r·cos(lat)·cos(lon)
//     y =  r·sin(lat)
//     z = −r·cos(lat)·sin(lon)
//
// Scene positions use double precision in the core; the renderer narrows them to
// float when it fills a vertex buffer.

#pragma once

#include <string>
#include <utility>
#include <vector>

#include "../Sky/Astro.hpp"
#include "../Sky/MathUtil.hpp"

namespace caelus {

class GeoMath {
public:
    // Rotational offset between the texture's prime meridian and the frame's.
    // Zero because the Earth mesh is built from this same convention.
    static constexpr double longitudeOffset = 0.0;

    // Mean Earth radius used for the scene's unit sphere, matching the equatorial
    // radius the propagators use for a₀ and altitude.
    static double earthRadiusKm() { return sky::EarthConstants::R_e; }

    // Unit vector on the sphere for a geodetic coordinate.
    static sky::Vec3 unitVector(double lat, double lon);

    // Position in scene units (1 = one Earth radius) for a geodetic coordinate.
    static sky::Vec3 scenePosition(double lat, double lon, double altKm);
    static sky::Vec3 scenePosition(const sky::LatLonAlt& lla) {
        return scenePosition(lla.lat, lla.lon, lla.alt);
    }

    // Position on a shell of the given scene radius.
    static sky::Vec3 scenePositionOnRadius(double lat, double lon, double radius);

    // Inverse of unitVector, in degrees.
    static std::pair<double, double> latLon(const sky::Vec3& unit);

    // Split a lat/lon polyline wherever it jumps across the antimeridian.
    static std::vector<std::vector<sky::LatLonAlt>> splitAtAntimeridian(
        const std::vector<sky::LatLonAlt>& points);

    // Great-circle distance in kilometres between two geodetic points.
    static double greatCircleKm(double lat1, double lon1, double lat2, double lon2);

    // Normalise an angle in degrees into [−180, 180).
    static double wrapLongitude(double lon);

    // Interpolate between two scene positions along the sphere rather than
    // through it, so fast movers sweep along their arc instead of cutting a chord.
    static sky::Vec3 slerp(const sky::Vec3& a, const sky::Vec3& b, double t);
};

}  // namespace caelus

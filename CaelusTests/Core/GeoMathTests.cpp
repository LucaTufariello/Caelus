// GeoMathTests.cpp — ported from CaelusTests/GeoMathTests.swift.
//
// The scene's frame convention is the one thing every other layer depends on:
// get it wrong and the ground tracks land in the wrong hemisphere.

#include "TestSupport.hpp"

#include "Geo/GeoMath.hpp"
#include "Sky/MathUtil.hpp"

#include <cmath>
#include <set>
#include <vector>

using namespace caelus;

namespace {
constexpr double tolerance = 1e-5;
}

TEST(GeoMath, EquatorPrimeMeridianIsPositiveX) {
    const sky::Vec3 p = GeoMath::unitVector(0, 0);
    CHECK_NEAR(p.x, 1.0, tolerance);
    CHECK_NEAR(p.y, 0.0, tolerance);
    CHECK_NEAR(p.z, 0.0, tolerance);
}

TEST(GeoMath, NorthPoleIsPositiveY) {
    const sky::Vec3 p = GeoMath::unitVector(90, 0);
    CHECK_NEAR(p.x, 0.0, tolerance);
    CHECK_NEAR(p.y, 1.0, tolerance);
    CHECK_NEAR(p.z, 0.0, tolerance);
}

TEST(GeoMath, SouthPoleIsNegativeY) {
    const sky::Vec3 p = GeoMath::unitVector(-90, 0);
    CHECK_NEAR(p.y, -1.0, tolerance);
}

TEST(GeoMath, EastIsNegativeZ) {
    const sky::Vec3 p = GeoMath::unitVector(0, 90);
    CHECK_NEAR(p.x, 0.0, tolerance);
    CHECK_NEAR(p.y, 0.0, tolerance);
    CHECK_NEAR(p.z, -1.0, tolerance);
}

TEST(GeoMath, WestIsPositiveZ) {
    const sky::Vec3 p = GeoMath::unitVector(0, -90);
    CHECK_NEAR(p.z, 1.0, tolerance);
}

TEST(GeoMath, AntimeridianIsNegativeX) {
    const sky::Vec3 p = GeoMath::unitVector(0, 180);
    CHECK_NEAR(p.x, -1.0, tolerance);
}

TEST(GeoMath, LongitudeOffsetIsZero) {
    // The Earth node builds its own UV sphere from this convention, so the
    // texture's prime meridian and the frame's must coincide.
    CHECK_EQ(GeoMath::longitudeOffset, 0.0);
}

TEST(GeoMath, UnitVectorRoundTrips) {
    for (double latitude = -85.0; latitude <= 85.0; latitude += 17.0) {
        for (double longitude = -180.0; longitude < 180.0; longitude += 23.0) {
            const sky::Vec3 unit = GeoMath::unitVector(latitude, longitude);
            const auto [lat, lon] = GeoMath::latLon(unit);
            CHECK_NEAR(lat, latitude, 1e-4);
            CHECK_NEAR(GeoMath::wrapLongitude(lon - longitude), 0.0, 1e-4);
        }
    }
}

TEST(GeoMath, UnitVectorIsUnitLength) {
    for (double latitude = -90.0; latitude <= 90.0; latitude += 15.0) {
        const sky::Vec3 unit = GeoMath::unitVector(latitude, 37);
        CHECK_NEAR(unit.magnitude(), 1.0, tolerance);
    }
}

TEST(GeoMath, AltitudeScalesRadius) {
    const sky::Vec3 surface = GeoMath::scenePosition(41.9, 12.5, 0);
    const sky::Vec3 orbit = GeoMath::scenePosition(41.9, 12.5, 400);

    CHECK_NEAR(surface.magnitude(), 1.0, tolerance);
    CHECK_NEAR(orbit.magnitude(), 1.0 + 400.0 / GeoMath::earthRadiusKm(), tolerance);
    // Same ray from the centre.
    CHECK_NEAR(sky::normalize(surface).x, sky::normalize(orbit).x, tolerance);
}

TEST(GeoMath, GreatCircleRomeToLondon) {
    const double km = GeoMath::greatCircleKm(41.9028, 12.4964, 51.5074, -0.1278);
    // Published great-circle distance is about 1435 km.
    CHECK_NEAR(km, 1435.0, 10.0);
}

TEST(GeoMath, GreatCircleIsZeroForSamePoint) {
    CHECK_NEAR(GeoMath::greatCircleKm(10, 20, 10, 20), 0.0, 1e-6);
}

TEST(GeoMath, GreatCircleIsSymmetric) {
    const double a = GeoMath::greatCircleKm(41.9, 12.5, -33.87, 151.2);
    const double b = GeoMath::greatCircleKm(-33.87, 151.2, 41.9, 12.5);
    CHECK_NEAR(a, b, 1e-6);
}

TEST(GeoMath, WrapLongitude) {
    CHECK_NEAR(GeoMath::wrapLongitude(0), 0.0, 1e-9);
    CHECK_NEAR(GeoMath::wrapLongitude(179.5), 179.5, 1e-9);
    CHECK_NEAR(GeoMath::wrapLongitude(180), -180.0, 1e-9);
    CHECK_NEAR(GeoMath::wrapLongitude(181), -179.0, 1e-9);
    CHECK_NEAR(GeoMath::wrapLongitude(-181), 179.0, 1e-9);
    CHECK_NEAR(GeoMath::wrapLongitude(540), -180.0, 1e-9);
}

TEST(GeoMath, GroundTrackSplitsAtAntimeridian) {
    const std::vector<sky::LatLonAlt> points = {
        sky::LatLonAlt{10, 178, 400},
        sky::LatLonAlt{11, 179, 400},
        sky::LatLonAlt{12, -179, 400},
        sky::LatLonAlt{13, -178, 400},
    };
    const auto runs = GeoMath::splitAtAntimeridian(points);
    CHECK_EQ(runs.size(), size_t(2));
    CHECK_EQ(runs[0].size(), size_t(2));
    CHECK_EQ(runs[1].size(), size_t(2));
}

TEST(GeoMath, ContinuousTrackIsNotSplit) {
    std::vector<sky::LatLonAlt> points;
    for (int index = 0; index < 10; ++index) {
        points.push_back(sky::LatLonAlt{static_cast<double>(index),
                                        static_cast<double>(index) * 2, 400});
    }
    CHECK_EQ(GeoMath::splitAtAntimeridian(points).size(), size_t(1));
}

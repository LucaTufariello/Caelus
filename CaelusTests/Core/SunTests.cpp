// SunTests.cpp — ported from CaelusTests/SunTests.swift.

#include "TestSupport.hpp"

#include "Geo/GeoMath.hpp"
#include "Propagation/SunCalculator.hpp"

#include <cmath>

using namespace caelus;
using test::utc;

TEST(Sun, SubsolarLatitudeStaysWithinTheTropics) {
    for (int day = 0; day < 365; day += 11) {
        const Date date = utc(2026, 1, 1) + static_cast<double>(day) * 86400.0;
        const sky::LatLonAlt point = SunCalculator::subsolarPointAt(date);
        CHECK(std::fabs(point.lat) <= 23.6);
    }
}

TEST(Sun, SubsolarLatitudeAtSolstices) {
    // June solstice: the Sun stands over the Tropic of Cancer.
    const sky::LatLonAlt june = SunCalculator::subsolarPointAt(utc(2026, 6, 21, 12));
    CHECK_NEAR(june.lat, 23.4, 0.6);

    // December solstice: over the Tropic of Capricorn.
    const sky::LatLonAlt december = SunCalculator::subsolarPointAt(utc(2026, 12, 21, 12));
    CHECK_NEAR(december.lat, -23.4, 0.6);
}

TEST(Sun, SubsolarLongitudeMovesWestThroughTheDay) {
    const sky::LatLonAlt noon = SunCalculator::subsolarPointAt(utc(2026, 3, 20, 12));
    const sky::LatLonAlt later = SunCalculator::subsolarPointAt(utc(2026, 3, 20, 15));
    // Three hours later the Sun is 45° further west.
    CHECK_NEAR(GeoMath::wrapLongitude(later.lon - noon.lon), -45.0, 1.5);
}

TEST(Sun, SceneDirectionIsUnitLength) {
    for (int hour = 0; hour < 24; hour += 3) {
        const sky::Vec3 direction = SunCalculator::sceneDirection(utc(2026, 5, 4, hour));
        CHECK_NEAR(direction.magnitude(), 1.0, 1e-5);
    }
}

TEST(Sun, SceneDirectionMatchesSubsolarPoint) {
    const Date date = utc(2026, 8, 12, 9);
    const sky::LatLonAlt point = SunCalculator::subsolarPointAt(date);
    const sky::Vec3 direction = SunCalculator::sceneDirection(date);
    const sky::Vec3 expected = GeoMath::unitVector(point.lat, point.lon);

    CHECK_NEAR(direction.x, expected.x, 1e-4);
    CHECK_NEAR(direction.y, expected.y, 1e-4);
    CHECK_NEAR(direction.z, expected.z, 1e-4);
}

TEST(Sun, RomeIsDarkAtLocalMidnight) {
    // Rome is UTC+2 in summer; 22:00 UTC is midnight local.
    CHECK(SunCalculator::isObserverDark(utc(2026, 7, 15, 22), ObserverSite::rome()));
}

TEST(Sun, RomeIsLitAtLocalNoon) {
    CHECK(!SunCalculator::isObserverDark(utc(2026, 7, 15, 10), ObserverSite::rome()));
}

TEST(Sun, SunElevationIsHigherInSummer) {
    const double summer = SunCalculator::elevationDeg(utc(2026, 6, 21, 11), ObserverSite::rome());
    const double winter = SunCalculator::elevationDeg(utc(2026, 12, 21, 11), ObserverSite::rome());
    CHECK(summer > winter);
    CHECK(summer > 60.0);
}

TEST(Sun, SunElevationAtNightIsNegative) {
    CHECK(SunCalculator::elevationDeg(utc(2026, 3, 1, 0), ObserverSite::rome()) < 0.0);
}

TEST(Sun, SatelliteOnTheDaySideIsSunlit) {
    const Date date = utc(2026, 4, 1, 12);
    const sky::Vec3 sun = SunCalculator::sunUnitECI(sky::julianFromDate(date));
    const sky::Vec3 onDaySide(sun.x * 7000.0, sun.y * 7000.0, sun.z * 7000.0);
    CHECK(SunCalculator::isSunlit(onDaySide, sun));
}

TEST(Sun, SatelliteBehindTheEarthIsInEclipse) {
    const Date date = utc(2026, 4, 1, 12);
    const sky::Vec3 sun = SunCalculator::sunUnitECI(sky::julianFromDate(date));
    const sky::Vec3 behind(-sun.x * 7000.0, -sun.y * 7000.0, -sun.z * 7000.0);
    CHECK(!SunCalculator::isSunlit(behind, sun));
}

TEST(Sun, LightLevelLabelsFollowTheSun) {
    CHECK_EQ(SunCalculator::lightLevel(utc(2026, 6, 21, 11), ObserverSite::rome()),
             std::string("Daylight"));
    CHECK_EQ(SunCalculator::lightLevel(utc(2026, 6, 21, 22), ObserverSite::rome()),
             std::string("Night"));
}

// PassTests.cpp — ported from CaelusTests/PassTests.swift.

#include "TestSupport.hpp"
#include "TLEFixtures.hpp"

#include "Data/TLEParser.hpp"
#include "Propagation/PassPredictor.hpp"

#include <algorithm>
#include <cmath>
#include <string>

using namespace caelus;

namespace {

sky::Satellite iss() {
    return sky::Satellite(TLEParser::parse(fixtures::issDocument(), {}).records.front().elements);
}

const ObserverSite rome = ObserverSite::rome();

}  // namespace

TEST(Pass, ISSRisesOverRomeWithinADay) {
    const auto passes =
        PassPredictor::passes(iss(), rome, sky::nowDate(), 24, 10, 20);

    // The ISS completes about 15.5 orbits a day; a mid-latitude site sees
    // roughly four to six passes above 10°.
    CHECK(passes.size() >= 2);
    CHECK(passes.size() <= 12);
}

TEST(Pass, PassesAreWellFormed) {
    const auto passes = PassPredictor::passes(iss(), rome, sky::nowDate(), 24, 10, 20);
    CHECK(!passes.empty());

    for (const PassEvent& pass : passes) {
        CHECK(pass.rise < pass.peak);
        CHECK(pass.peak < pass.set);
        CHECK(pass.duration() > 60.0);
        CHECK(pass.duration() < 900.0);
        CHECK(pass.maxElevation >= 10.0);
        CHECK(pass.maxElevation <= 90.0);
        CHECK(pass.rangeAtPeakKm > 300.0);
        CHECK(pass.rangeAtPeakKm < 3000.0);
        CHECK(pass.peakAzimuth >= 0.0);
        CHECK(pass.peakAzimuth < 360.0);
        CHECK(pass.riseAzimuth >= 0.0);
        CHECK(pass.riseAzimuth < 360.0);
        CHECK(pass.setAzimuth >= 0.0);
        CHECK(pass.setAzimuth < 360.0);
        CHECK(!pass.riseDirection().empty());
        CHECK(!pass.peakDirection().empty());
        CHECK(!pass.setDirection().empty());
    }
}

TEST(Pass, PassesAreChronologicalAndDisjoint) {
    const auto passes = PassPredictor::passes(iss(), rome, sky::nowDate(), 48, 10, 20);
    for (size_t index = 1; index < passes.size(); ++index) {
        CHECK(passes[index - 1].set < passes[index].rise);
    }
}

TEST(Pass, HigherElevationThresholdYieldsFewerPasses) {
    const Date start = sky::nowDate();
    const auto low = PassPredictor::passes(iss(), rome, start, 48, 10, 50);
    const auto high = PassPredictor::passes(iss(), rome, start, 48, 60, 50);

    CHECK(high.size() <= low.size());
    for (const PassEvent& pass : high) CHECK(pass.maxElevation >= 60.0);
}

TEST(Pass, LimitIsRespected) {
    const auto passes = PassPredictor::passes(iss(), rome, sky::nowDate(), 72, 0, 3);
    CHECK(passes.size() <= 3);
}

TEST(Pass, ISSNeverRisesAboveTenDegreesFromThePole) {
    const ObserverSite southPole{"South Pole", -89.9, 0.0, 0.0};
    const auto passes = PassPredictor::passes(iss(), southPole, sky::nowDate(), 24, 10, 20);
    CHECK(passes.empty());
}

TEST(Pass, CompassDirections) {
    CHECK_EQ(Compass::direction(0), std::string("N"));
    CHECK_EQ(Compass::direction(90), std::string("E"));
    CHECK_EQ(Compass::direction(180), std::string("S"));
    CHECK_EQ(Compass::direction(270), std::string("W"));
    CHECK_EQ(Compass::direction(359), std::string("N"));
    CHECK_EQ(Compass::direction(-90), std::string("W"));
    CHECK_EQ(Compass::direction(45), std::string("NE"));
    CHECK_EQ(Compass::direction(225), std::string("SW"));
}

TEST(Pass, ElevationProfileCoversThePass) {
    const auto passes = PassPredictor::passes(iss(), rome, sky::nowDate(), 24, 10, 20);
    CHECK(!passes.empty());
    if (passes.empty()) return;

    const auto profile = PassPredictor::elevationProfile(iss(), rome, passes.front(), 48);
    // Inclusive of both endpoints: 48 intervals → 49 samples, as in Swift.
    CHECK_EQ(profile.size(), size_t(49));
    double peak = -91.0;
    for (double elevation : profile) peak = std::max(peak, elevation);
    // The sampled maximum should be close to the refined peak elevation.
    CHECK_NEAR(peak, passes.front().maxElevation, 5.0);
}

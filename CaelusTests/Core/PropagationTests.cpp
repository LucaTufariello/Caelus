// PropagationTests.cpp — ported from CaelusTests/PropagationTests.swift.
//
// Sanity checks on the SGP4 pipeline, plus the performance gate the app's
// budget depends on: a full 16 000-object tick under 250 ms.

#include "TestSupport.hpp"
#include "TLEFixtures.hpp"

#include "Data/TLEParser.hpp"
#include "Geo/GeoMath.hpp"
#include "Propagation/PropagationEngine.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace caelus;
using sky::nowDate;

namespace {

std::vector<SatelliteRecord> records(const std::string& text) {
    return TLEParser::parse(text, {}).records;
}

// The engine holds a mutex, so it is neither copyable nor movable; each test
// builds its own and loads it in place.
void loadISS(PropagationEngine& engine) { engine.load(records(fixtures::issDocument())); }

}  // namespace

TEST(Propagation, LongitudeIsAlwaysWrapped) {
    PropagationEngine engine;
    loadISS(engine);
    [[maybe_unused]] const ObserverSite rome = ObserverSite::rome();

    const Date start = nowDate();
    for (int step = 0; step < 24; ++step) {
        const Date date = start + static_cast<double>(step) * 300.0;
        const auto state = engine.state(0, date, &rome);
        CHECK(state.has_value());
        if (!state) continue;
        CHECK(state->longitude >= -180.0);
        CHECK(state->longitude <= 180.0);
    }

    const auto samples = engine.trackSamples(0, start, 95, 60);
    CHECK(!samples.empty());
    for (const TrackSample& sample : samples) {
        CHECK(sample.longitude >= -180.0);
        CHECK(sample.longitude <= 180.0);
    }
}

TEST(Propagation, ISSPropagatesToAPlausibleOrbit) {
    PropagationEngine engine;
    loadISS(engine);
    [[maybe_unused]] const ObserverSite rome = ObserverSite::rome();

    const SatelliteSnapshot snapshot = engine.tick(nowDate());
    CHECK_EQ(snapshot.count(), size_t(1));
    CHECK(snapshot.valid[0]);
    CHECK_EQ(snapshot.failures, 0);

    const double radius = snapshot.positions[0].magnitude();
    const double altitude = (radius - 1.0) * GeoMath::earthRadiusKm();
    // The ISS orbits between roughly 400 and 430 km.
    CHECK(altitude > 380.0);
    CHECK(altitude < 460.0);
}

TEST(Propagation, ISSStateReportsVelocityAndPosition) {
    PropagationEngine engine;
    loadISS(engine);
    [[maybe_unused]] const ObserverSite rome = ObserverSite::rome();

    const auto state = engine.state(0, nowDate(), &rome);
    CHECK(state.has_value());
    if (!state) return;
    // Orbital velocity at ISS altitude is about 7.66 km/s.
    CHECK_NEAR(state->velocityKmS, 7.66, 0.15);
    CHECK(std::fabs(state->latitude) <= 52.0);
    CHECK(state->longitude >= -180.0);
    CHECK(state->longitude <= 180.0);
    CHECK_NEAR((state->position.magnitude() - 1.0) * GeoMath::earthRadiusKm(),
               state->altitudeKm, 1.0);
}

TEST(Propagation, ObserverGeometryIsConsistent) {
    PropagationEngine engine;
    loadISS(engine);
    [[maybe_unused]] const ObserverSite rome = ObserverSite::rome();

    const auto state = engine.state(0, nowDate(), &rome);
    CHECK(state.has_value());
    if (!state) return;
    CHECK(state->rangeToObserverKm.has_value());
    CHECK(state->elevationFromObserver.has_value());
    CHECK(state->azimuthFromObserver.has_value());
    if (!state->rangeToObserverKm || !state->elevationFromObserver ||
        !state->azimuthFromObserver) {
        return;
    }

    // Range is bounded by the horizon distance and the antipode.
    CHECK(*state->rangeToObserverKm > 300.0);
    CHECK(*state->rangeToObserverKm < 20000.0);
    CHECK(*state->elevationFromObserver >= -90.0);
    CHECK(*state->elevationFromObserver <= 90.0);
    CHECK(*state->azimuthFromObserver >= 0.0);
    CHECK(*state->azimuthFromObserver < 360.0);
}

TEST(Propagation, PositionMovesOverTime) {
    PropagationEngine engine;
    loadISS(engine);
    [[maybe_unused]] const ObserverSite rome = ObserverSite::rome();

    const Date start = nowDate();
    const SatelliteSnapshot first = engine.tick(start);
    const SatelliteSnapshot later = engine.tick(start + 60.0);

    const double moved = (first.positions[0] - later.positions[0]).magnitude();
    // About one degree of arc per 60 s, i.e. roughly 0.02 scene units.
    CHECK(moved > 0.005);
    CHECK(moved < 0.1);
}

TEST(Propagation, EmptyCatalogIsHarmless) {
    PropagationEngine engine;
    engine.load({});
    const SatelliteSnapshot snapshot = engine.tick(nowDate());
    CHECK_EQ(snapshot.count(), size_t(0));
    CHECK_EQ(snapshot.failures, 0);
}

TEST(Propagation, StateForOutOfRangeIndexIsNil) {
    PropagationEngine engine;
    loadISS(engine);
    [[maybe_unused]] const ObserverSite rome = ObserverSite::rome();
    CHECK(!engine.state(99, nowDate(), &rome).has_value());
    CHECK(!engine.record(99).has_value());
    CHECK(!engine.satellite(99).has_value());
}

TEST(Propagation, SyntheticCatalogPropagatesCompletely) {
    PropagationEngine engine;
    engine.load(records(fixtures::syntheticDocument(2000)));
    CHECK_EQ(engine.loadedCount(), size_t(2000));

    const SatelliteSnapshot snapshot = engine.tick(nowDate());
    CHECK_EQ(snapshot.count(), size_t(2000));
    size_t valid = 0;
    for (bool flag : snapshot.valid) valid += flag ? 1 : 0;
    CHECK_EQ(valid, size_t(2000));
    CHECK_EQ(snapshot.failures, 0);
    CHECK(engine.unpropagatableIndices().empty());
}

TEST(Propagation, SnapshotIsInCatalogOrder) {
    PropagationEngine engine;
    engine.load(records(fixtures::syntheticDocument(200)));

    const SatelliteSnapshot snapshot = engine.tick(nowDate());
    for (size_t index : {size_t(0), size_t(37), size_t(199)}) {
        const auto state = engine.state(index, snapshot.time, nullptr);
        CHECK(state.has_value());
        if (!state) continue;
        CHECK_NEAR(snapshot.positions[index].x, state->position.x, 1e-9);
        CHECK_NEAR(snapshot.positions[index].y, state->position.y, 1e-9);
        CHECK_NEAR(snapshot.positions[index].z, state->position.z, 1e-9);
    }
}

TEST(Propagation, SnapshotBufferHandsOffTwoInstants) {
    SnapshotBuffer buffer;
    CHECK_EQ(buffer.currentTime(), -1.0e12);

    SatelliteSnapshot first;
    first.time = 100.0;
    first.positions = {sky::Vec3(1, 0, 0)};
    first.valid = {true};

    SatelliteSnapshot second;
    second.time = 101.0;
    second.positions = {sky::Vec3(0, 1, 0)};
    second.valid = {true};

    buffer.push(first);
    buffer.push(second);

    auto [previous, current] = buffer.pair();
    CHECK_EQ(previous.time, 100.0);
    CHECK_EQ(current.time, 101.0);
    CHECK_NEAR(previous.positions[0].x, 1.0, 0.0);
    CHECK_NEAR(current.positions[0].y, 1.0, 0.0);

    // A snapshot for the same instant replaces rather than shifting.
    SatelliteSnapshot replacement;
    replacement.time = 101.0;
    replacement.positions = {sky::Vec3(0, 0, 1)};
    replacement.valid = {true};
    buffer.push(replacement);
    auto [previous2, current2] = buffer.pair();
    CHECK_EQ(previous2.time, 100.0);
    CHECK_NEAR(current2.positions[0].z, 1.0, 0.0);

    buffer.clear();
    auto [clearedPrevious, clearedCurrent] = buffer.pair();
    CHECK_EQ(clearedPrevious.count(), size_t(0));
    CHECK_EQ(clearedCurrent.count(), size_t(0));
}

TEST(Propagation, PerformanceBudget) {
    PropagationEngine engine;
    const auto catalog = records(fixtures::syntheticDocument(16000));
    CHECK_EQ(catalog.size(), size_t(16000));

    engine.load(catalog);

    // Warm the propagators so the measurement is steady-state.
    engine.tick(nowDate());

    std::vector<double> samples;
    for (int step = 0; step < 3; ++step) {
        const SatelliteSnapshot snapshot = engine.tick(nowDate() + static_cast<double>(step));
        size_t valid = 0;
        for (bool flag : snapshot.valid) valid += flag ? 1 : 0;
        CHECK_EQ(valid, size_t(16000));
        samples.push_back(snapshot.duration);
    }

    std::sort(samples.begin(), samples.end());
    const double median = samples[samples.size() / 2];
    std::printf("    SGP4 16k tick: %.1f ms, %.1f ms, %.1f ms\n", samples[0] * 1000.0,
                samples[1] * 1000.0, samples[2] * 1000.0);
    CHECK(median < 0.250);
}

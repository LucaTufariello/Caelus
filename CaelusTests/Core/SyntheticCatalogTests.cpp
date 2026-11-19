// SyntheticCatalogTests.cpp — ported from CaelusTests/SyntheticCatalogTests.swift.
//
// The QA generator ships in the app, so its output has to be as valid as any
// downloaded element set — otherwise the performance path it exists to
// exercise is not the path a real catalog takes.

#include "TestSupport.hpp"

#include "Data/SyntheticCatalog.hpp"
#include "Data/TLEParser.hpp"

#include <cmath>
#include <set>
#include <string>

using namespace caelus;

TEST(SyntheticCatalog, GeneratesRequestedCount) {
    const SyntheticCatalog::Made made = SyntheticCatalog::make(1000);
    CHECK_EQ(made.catalog.count(), size_t(1000));
    CHECK_EQ(made.diagnostics.unpropagatable, 0);
    CHECK_EQ(made.diagnostics.parseFailures, 0);
}

TEST(SyntheticCatalog, EveryRecordParsesWithMatchingChecksums) {
    const SyntheticCatalog::Made made = SyntheticCatalog::make(200);
    CHECK_EQ(made.catalog.count(), size_t(200));

    std::set<int> ids;
    for (const SatelliteRecord& record : made.catalog.records) {
        ids.insert(record.id);
        CHECK(!record.name.empty());
        CHECK(record.elements.n0 > 0.0);
    }
    CHECK_EQ(ids.size(), size_t(200));
}

TEST(SyntheticCatalog, GroupCountsSumToCatalog) {
    const SyntheticCatalog::Made made = SyntheticCatalog::make(2000);

    size_t total = 0;
    for (SatelliteGroup group : allGroups()) total += made.catalog.countIn(group);
    CHECK_EQ(total, made.catalog.count());
    CHECK_EQ(made.catalog.countIn(SatelliteGroup::stations), size_t(0));
}

TEST(SyntheticCatalog, ShellsLandAtPlausibleAltitudes) {
    const SyntheticCatalog::Made made = SyntheticCatalog::make(400);

    int leo = 0;
    int geo = 0;
    for (const SatelliteRecord& record : made.catalog.records) {
        if (record.groups.count(SatelliteGroup::starlink) == 1) {
            ++leo;
            CHECK(record.perigeeKm() > 300.0);
            CHECK(record.apogeeKm() < 1000.0);
        }
        if (record.groups.count(SatelliteGroup::weather) == 1) {
            ++geo;
            // Geostationary: one revolution per sidereal day, ±1 %.
            CHECK_NEAR(record.periodMinutes(), 1436.0, 15.0);
        }
    }
    CHECK(leo > 0);
    CHECK(geo > 0);
}

TEST(SyntheticCatalog, RaanSpansTheOrbitPlane) {
    const SyntheticCatalog::Made made = SyntheticCatalog::make(400);
    std::set<long> nodes;
    for (const SatelliteRecord& record : made.catalog.records) {
        nodes.insert(std::lround(record.raanDeg()));
    }
    CHECK(nodes.size() > 300);
}

TEST(SyntheticCatalog, LinesRoundTripThroughTheParser) {
    // The generator's own text must parse exactly as it does when written to
    // disk — the app's synthetic mode goes through the same path.
    const std::string line1 = SyntheticCatalog::makeLine1(90000);
    const std::string line2 = SyntheticCatalog::makeLine2(90000, 53.0, 10.0, 0.0004,
                                                          100.0, 20.0, 15.5);
    const TLEParser::Result parsed =
        TLEParser::parse("SYNTH-90000\n" + line1 + "\n" + line2 + "\n", {});
    CHECK_EQ(parsed.records.size(), size_t(1));
    CHECK(parsed.failures.empty());
}

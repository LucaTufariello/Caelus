// TLEParserTests.cpp — ported from CaelusTests/TLEParserTests.swift.

#include "TestSupport.hpp"
#include "TLEFixtures.hpp"

#include "Data/TLEParser.hpp"
#include "Sky/TimeUtil.hpp"

#include <set>

using namespace caelus;

TEST(TLEParser, ParsesISS) {
    const TLEParser::Result result =
        TLEParser::parse(fixtures::issDocument(), {SatelliteGroup::stations});

    CHECK_EQ(result.records.size(), size_t(1));
    CHECK(result.failures.empty());

    const SatelliteRecord& record = result.records.front();
    CHECK_EQ(record.id, 25544);
    CHECK_EQ(record.name, std::string("ISS (ZARYA)"));
    CHECK_EQ(record.cosparID(), std::string("1998-067A"));
    CHECK_EQ(record.groups.size(), size_t(1));
    CHECK(record.groups.count(SatelliteGroup::stations) == 1);
    CHECK(record.renderGroup() == SatelliteGroup::stations);

    CHECK_NEAR(record.inclinationDeg(), 51.6323, 1e-4);
    CHECK_NEAR(record.eccentricity(), 0.0007326, 1e-7);
    CHECK_NEAR(record.raanDeg(), 291.9174, 1e-4);

    // Mean motion 15.4931 rev/day → 92.94 min.
    CHECK_NEAR(record.periodMinutes(), 92.94, 0.02);
    CHECK_NEAR(record.perigeeKm(), 415.0, 15.0);
    CHECK_NEAR(record.apogeeKm(), 425.0, 15.0);
}

TEST(TLEParser, EpochIsParsed) {
    const TLEParser::Result result = TLEParser::parse(fixtures::issDocument(), {});
    CHECK_EQ(result.records.size(), size_t(1));
    // 2026 day 315.33607970 → 11 November 2026, 08:03 UTC.
    const sky::CivilTime parts = sky::civilTime(result.records.front().epoch);
    CHECK_EQ(parts.year, 2026);
    CHECK_EQ(parts.month, 11);
    CHECK_EQ(parts.day, 11);
    CHECK_EQ(parts.hour, 8);
}

TEST(TLEParser, CorruptedChecksumIsRejected) {
    std::string line = fixtures::issLine1;
    const char last = line.back();
    line.back() = last == '6' ? '7' : '6';

    const TLEParser::Result result =
        TLEParser::parse("ISS\n" + line + "\n" + fixtures::issLine2 + "\n", {});
    CHECK(result.records.empty());
    CHECK_EQ(result.failures.size(), size_t(1));
    CHECK_EQ(result.failures.front().reason, std::string("line 1 checksum"));
}

TEST(TLEParser, CorruptedDigitIsRejected) {
    std::string broken = fixtures::issLine1;
    broken[53] = '9';

    const TLEParser::Result result =
        TLEParser::parse("ISS\n" + broken + "\n" + fixtures::issLine2 + "\n", {});
    CHECK(result.records.empty());
    CHECK_EQ(result.failures.front().reason, std::string("line 1 checksum"));
}

TEST(TLEParser, RecomputedChecksumIsAccepted) {
    const std::string fixed = fixtures::tleLine(fixtures::issLine1.substr(0, 68), {{53, " 17018-3"}});
    const TLEParser::Result result =
        TLEParser::parse("ISS\n" + fixed + "\n" + fixtures::issLine2 + "\n", {});
    CHECK_EQ(result.records.size(), size_t(1));
}

TEST(TLEParser, MissingSecondLineIsReported) {
    const TLEParser::Result result =
        TLEParser::parse("ORPHAN\n" + fixtures::issLine1 + "\n", {});
    CHECK(result.records.empty());
    CHECK_EQ(result.failures.size(), size_t(1));
    CHECK_EQ(result.failures.front().reason, std::string("truncated record"));
}

TEST(TLEParser, MismatchedNoradIDsAreRejected) {
    const TLEParser::Result result =
        TLEParser::parse("MISMATCH\n" + fixtures::issLine1 + "\n" + fixtures::poiskLine2 + "\n",
                         {});
    CHECK(result.records.empty());
    CHECK_EQ(result.failures.front().reason, std::string("NORAD id mismatch (25544 / 36086)"));
}

TEST(TLEParser, EmptyDocumentProducesNothing) {
    const TLEParser::Result result = TLEParser::parse("", {});
    CHECK(result.records.empty());
    CHECK(result.failures.empty());
}

TEST(TLEParser, Alpha5NoradIDs) {
    const auto id = [](const std::string& field) {
        const std::string line = "1 " + field;
        return TLEParser::noradID(std::vector<uint8_t>(line.begin(), line.end()));
    };
    CHECK(id("25544") == std::optional<int>(25544));
    CHECK(id("A0001") == std::optional<int>(100001));
    CHECK(id("H9999") == std::optional<int>(179999));
    CHECK(id("J0000") == std::optional<int>(180000));
    CHECK(id("N9999") == std::optional<int>(229999));
    CHECK(id("P0000") == std::optional<int>(230000));
    CHECK(id("Z9999") == std::optional<int>(339999));
    // "I" and "O" are deliberately excluded from the alphabet.
    CHECK(!id("I0000").has_value());
    CHECK(!id("O0000").has_value());
}

TEST(TLEParser, ThreeLineElementNamePrefixIsStripped) {
    CHECK_EQ(TLEParser::normaliseName("0 ISS (ZARYA)"), std::string("ISS (ZARYA)"));
    CHECK_EQ(TLEParser::normaliseName("  ISS (ZARYA)  "), std::string("ISS (ZARYA)"));
}

TEST(TLEParser, LongNamesAreTruncated) {
    const std::string longName(40, 'A');
    CHECK_EQ(TLEParser::normaliseName(longName).size(), size_t(24));
}

TEST(TLEParser, MultipleRecordsAndPartialFailure) {
    const std::string document = fixtures::issDocument() + "BROKEN\n" + fixtures::poiskLine1 +
                                 "\nnot a line 2\nPOISK\n" + fixtures::poiskLine1 + "\n" +
                                 fixtures::poiskLine2 + "\n";

    const TLEParser::Result result = TLEParser::parse(document, {SatelliteGroup::stations});
    CHECK_EQ(result.records.size(), size_t(2));
    CHECK_EQ(result.failures.size(), size_t(1));

    std::set<int> ids;
    for (const SatelliteRecord& record : result.records) ids.insert(record.id);
    CHECK(ids == std::set<int>({25544, 36086}));
}

TEST(TLEParser, GeneratedCatalogIsFullyValid) {
    const TLEParser::Result result = TLEParser::parse(fixtures::syntheticDocument(500), {});
    CHECK_EQ(result.records.size(), size_t(500));
    CHECK(result.failures.empty());

    std::set<int> ids;
    for (const SatelliteRecord& record : result.records) ids.insert(record.id);
    CHECK_EQ(ids.size(), size_t(500));
}

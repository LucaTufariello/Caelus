// CatalogTests.cpp — ported from CaelusTests/CatalogTests.swift.

#include "TestSupport.hpp"
#include "TLEFixtures.hpp"

#include "Data/SatelliteCatalog.hpp"
#include "Data/TLEParser.hpp"

#include <algorithm>
#include <set>
#include <string>
#include <vector>

using namespace caelus;

namespace {

SatelliteCatalog::Batch batch(const std::string& text, const std::string& group,
                              const std::set<SatelliteGroup>& tags) {
    TLEParser::Result parsed = TLEParser::parse(text, tags);
    return SatelliteCatalog::Batch{group, std::move(parsed.records), tags,
                                   std::move(parsed.failures)};
}

size_t totalRenderIndices(const SatelliteCatalog& catalog) {
    size_t total = 0;
    for (const auto& [group, indices] : catalog.renderIndices) total += indices.size();
    return total;
}

SatelliteCatalog makeSearchCatalog() {
    const std::string text =
        fixtures::document(25544, "ISS (ZARYA)", 10) +
        fixtures::document(44713, "STARLINK-1007", 20) +
        fixtures::document(44714, "STARLINK-1008", 30) +
        fixtures::document(20001, "NOAA 19", 40);

    const TLEParser::Result parsed = TLEParser::parse(text, {});
    return SatelliteCatalog::assemble({SatelliteCatalog::Batch{"active", parsed.records, {}, {}}})
        .catalog;
}

}  // namespace

TEST(Catalog, DuplicateRecordsMergeTagsAndKeepNewestEpoch) {
    // Same object served by two groups with different tags.
    const auto stations = batch(fixtures::issDocument(), "stations",
                                {SatelliteGroup::stations});
    const auto science = batch(fixtures::issDocument(), "science", {SatelliteGroup::science});

    const SatelliteCatalog::Assembled assembled =
        SatelliteCatalog::assemble({stations, science});

    CHECK_EQ(assembled.catalog.count(), size_t(1));
    CHECK_EQ(assembled.diagnostics.duplicateRecords, 1);

    const SatelliteRecord& record = assembled.catalog.records.front();
    CHECK(record.groups == std::set<SatelliteGroup>({SatelliteGroup::stations,
                                                     SatelliteGroup::science}));
    // Render priority puts stations first.
    CHECK(record.renderGroup() == SatelliteGroup::stations);
}

TEST(Catalog, NewestEpochWinsWhenDuplicatesDisagree) {
    // A record with a later epoch must supply the elements, whichever order the
    // batches arrive in.
    SatelliteRecord older = TLEParser::parse(fixtures::issDocument(), {}).records.front();
    SatelliteRecord newer = older;
    newer.epoch = older.epoch + 3600.0;

    SatelliteCatalog::Batch first{"active", {older}, {}, {}};
    SatelliteCatalog::Batch second{"stations", {newer}, {SatelliteGroup::stations}, {}};

    const SatelliteCatalog::Assembled assembled = SatelliteCatalog::assemble({first, second});
    CHECK_EQ(assembled.catalog.count(), size_t(1));
    CHECK_EQ(assembled.catalog.records.front().epoch, newer.epoch);
    CHECK_EQ(assembled.diagnostics.duplicateRecords, 1);
}

TEST(Catalog, RenderIndicesCoverEveryRecordExactlyOnce) {
    const std::string text = fixtures::syntheticDocument(40);
    const SatelliteCatalog::Assembled assembled =
        SatelliteCatalog::assemble({batch(text, "active", {})});

    CHECK_EQ(totalRenderIndices(assembled.catalog), assembled.catalog.count());

    std::set<size_t> flattened;
    for (const auto& [group, indices] : assembled.catalog.renderIndices) {
        flattened.insert(indices.begin(), indices.end());
    }
    CHECK_EQ(flattened.size(), assembled.catalog.count());
}

TEST(Catalog, StarlinkIsTaggedByNamePrefix) {
    const std::string document = fixtures::document(44713, "STARLINK-1007", 10);
    const SatelliteCatalog::Assembled assembled =
        SatelliteCatalog::assemble({batch(document, "active", {})});

    const SatelliteRecord& record = assembled.catalog.records.front();
    CHECK(record.groups.count(SatelliteGroup::starlink) == 1);
    CHECK(record.renderGroup() == SatelliteGroup::starlink);
}

TEST(Catalog, UntaggedRecordsBecomeOther) {
    const std::string document = fixtures::document(90001, "SOMETHING", 10);
    const SatelliteCatalog::Assembled assembled =
        SatelliteCatalog::assemble({batch(document, "active", {})});

    const SatelliteRecord& record = assembled.catalog.records.front();
    CHECK(record.groups == std::set<SatelliteGroup>({SatelliteGroup::other}));
    CHECK(record.renderGroup() == SatelliteGroup::other);
}

TEST(Catalog, OtherIsDroppedWhenARealTagExists) {
    const std::string document = fixtures::document(90002, "WEATHER BIRD", 10);
    const SatelliteCatalog::Assembled assembled = SatelliteCatalog::assemble(
        {batch(document, "active", {}), batch(document, "weather", {SatelliteGroup::weather})});

    CHECK_EQ(assembled.catalog.count(), size_t(1));
    const SatelliteRecord& record = assembled.catalog.records.front();
    CHECK(record.groups.count(SatelliteGroup::other) == 0);
    CHECK(record.renderGroup() == SatelliteGroup::weather);
}

TEST(Catalog, RecordsAreSortedByName) {
    const std::string text = fixtures::document(30003, "ZULU", 1) +
                             fixtures::document(10001, "ALPHA", 2) +
                             fixtures::document(20002, "MIKE", 3);

    const SatelliteCatalog::Assembled assembled =
        SatelliteCatalog::assemble({batch(text, "active", {})});

    CHECK_EQ(assembled.catalog.records.size(), size_t(3));
    CHECK_EQ(assembled.catalog.records[0].name, std::string("ALPHA"));
    CHECK_EQ(assembled.catalog.records[1].name, std::string("MIKE"));
    CHECK_EQ(assembled.catalog.records[2].name, std::string("ZULU"));
}

TEST(Catalog, NaturalSortPlacesNumbersByValue) {
    CHECK(localizedStandardCompare("STARLINK-9", "STARLINK-10") < 0);
    CHECK(localizedStandardCompare("STARLINK-1007", "STARLINK-1008") < 0);
    CHECK(localizedStandardCompare("alpha", "BETA") < 0);
}

TEST(Catalog, LookupByID) {
    const SatelliteCatalog::Assembled assembled =
        SatelliteCatalog::assemble({batch(fixtures::issDocument(), "active", {})});

    const std::optional<size_t> index = assembled.catalog.index(25544);
    CHECK(index.has_value());
    if (!index) return;
    CHECK_EQ(assembled.catalog.records[*index].name, std::string("ISS (ZARYA)"));

    const SatelliteRecord* record = assembled.catalog.record(25544);
    CHECK(record != nullptr);
    if (record != nullptr) CHECK_EQ(record->name, std::string("ISS (ZARYA)"));

    CHECK(!assembled.catalog.index(1).has_value());
    CHECK(assembled.catalog.record(1) == nullptr);
}

TEST(Catalog, SearchByNoradIDRanksExactMatchFirst) {
    const SatelliteCatalog catalog = makeSearchCatalog();
    const auto results = catalog.search("25544", {}, false, {});
    CHECK(!results.empty());
    if (!results.empty()) CHECK_EQ(catalog.records[results.front()].id, 25544);
}

TEST(Catalog, SearchByNamePrefix) {
    const SatelliteCatalog catalog = makeSearchCatalog();
    const auto results = catalog.search("ISS", {}, false, {});
    CHECK_EQ(results.size(), size_t(1));
    if (!results.empty()) CHECK_EQ(catalog.records[results.front()].name,
                                  std::string("ISS (ZARYA)"));
}

TEST(Catalog, SearchIsCaseAndDiacriticInsensitive) {
    const SatelliteCatalog catalog = makeSearchCatalog();
    CHECK_EQ(catalog.search("starlink", {}, false, {}).size(), size_t(2));
    CHECK_EQ(catalog.search("STARLINK", {}, false, {}).size(), size_t(2));
    CHECK_EQ(catalog.search("StArLiNk", {}, false, {}).size(), size_t(2));
}

TEST(Catalog, SearchRanksPrefixAboveSubstring) {
    const SatelliteCatalog catalog = makeSearchCatalog();
    const auto results = catalog.search("1007", {}, false, {});
    CHECK(!results.empty());
    if (!results.empty()) CHECK_EQ(catalog.records[results.front()].id, 44713);
}

TEST(Catalog, SearchRespectsGroupFilter) {
    const SatelliteCatalog catalog = makeSearchCatalog();
    const auto results = catalog.search("", {SatelliteGroup::starlink}, false, {});
    CHECK_EQ(results.size(), size_t(2));
    for (size_t index : results) {
        CHECK(catalog.records[index].name.rfind("STARLINK", 0) == 0);
    }
}

TEST(Catalog, SearchRespectsFavoritesOnly) {
    const SatelliteCatalog catalog = makeSearchCatalog();
    const auto results = catalog.search("", {}, true, {25544});
    CHECK_EQ(results.size(), size_t(1));
    if (!results.empty()) CHECK_EQ(catalog.records[results.front()].id, 25544);
}

TEST(Catalog, EmptyQueryReturnsEverythingInOrder) {
    const SatelliteCatalog catalog = makeSearchCatalog();
    const auto results = catalog.search("", {}, false, {});
    CHECK_EQ(results.size(), size_t(4));

    std::vector<size_t> sorted = results;
    std::sort(sorted.begin(), sorted.end());
    CHECK(results == sorted);
}

TEST(Catalog, NoMatchReturnsEmpty) {
    const SatelliteCatalog catalog = makeSearchCatalog();
    CHECK(catalog.search("nothing here", {}, false, {}).empty());
}

TEST(Catalog, SearchLimitIsRespected) {
    const SatelliteCatalog catalog = makeSearchCatalog();
    CHECK_EQ(catalog.search("", {}, false, {}, 2).size(), size_t(2));
}

TEST(Catalog, ParseFailuresAreCounted) {
    const std::string broken = "BROKEN\n" + fixtures::issLine1 + "\n";
    const SatelliteCatalog::Assembled assembled =
        SatelliteCatalog::assemble({batch(broken, "active", {})});

    CHECK_EQ(assembled.diagnostics.parseFailures, 1);
    CHECK(!assembled.diagnostics.isEmpty());
}

TEST(Catalog, EmptyCatalogIsSearchableAndIndexable) {
    const SatelliteCatalog catalog;
    CHECK_EQ(catalog.count(), size_t(0));
    CHECK(catalog.search("iss", {}, false, {}).empty());
    CHECK(!catalog.index(25544).has_value());
    CHECK_EQ(catalog.countIn(SatelliteGroup::stations), size_t(0));
}

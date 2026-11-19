// CacheTests.cpp — ported from CaelusTests/CacheTests.swift.

#include "TestSupport.hpp"
#include "TLEFixtures.hpp"

#include "Data/CacheStore.hpp"
#include "Support/FileSystem.hpp"

#include <string>

using namespace caelus;

namespace {

// A private directory per test run, removed by the caller.
struct TemporaryRoot {
    fsutil::path path;

    TemporaryRoot() {
        static int counter = 0;
        path = fsutil::temporaryDirectory() /
               ("CaelusTests-" + std::to_string(++counter) + "-" +
                std::to_string(static_cast<long long>(sky::nowDate())));
        fsutil::createDirectories(path);
    }

    ~TemporaryRoot() {
        std::error_code error;
        std::filesystem::remove_all(path, error);
    }

    TemporaryRoot(const TemporaryRoot&) = delete;
    TemporaryRoot& operator=(const TemporaryRoot&) = delete;
};

CacheMeta meta(const std::string& group, int count = 1) {
    CacheMeta entry;
    entry.group = group;
    entry.fetchedAt = sky::nowDate();
    entry.lastChecked = entry.fetchedAt;
    entry.count = count;
    return entry;
}

}  // namespace

TEST(Cache, SaveAndLoadText) {
    TemporaryRoot root;
    const CacheStore store(root.path);
    store.save("active", fixtures::issDocument(), meta("active"));

    CHECK(store.loadText("active") == std::optional<std::string>(fixtures::issDocument()));
    CHECK(!store.loadText("missing").has_value());
}

TEST(Cache, MetaRoundTrip) {
    TemporaryRoot root;
    const CacheStore store(root.path);
    store.save("active", fixtures::issDocument(), meta("active", 1));
    store.save("stations", fixtures::issDocument(), meta("stations", 1));

    const auto loaded = store.loadMeta();
    CHECK_EQ(loaded.size(), size_t(2));
    CHECK(loaded.count("active") == 1);
    CHECK(loaded.count("stations") == 1);
    if (loaded.count("active") == 1) CHECK_EQ(loaded.at("active").count, 1);
}

TEST(Cache, MetaPreservesEtagAndTimestamps) {
    TemporaryRoot root;
    const CacheStore store(root.path);
    CacheMeta entry = meta("active", 7);
    entry.etag = "W/\"abc123\"";
    store.save("active", fixtures::issDocument(), entry);

    const auto loaded = store.loadMeta();
    CHECK(loaded.count("active") == 1);
    if (loaded.count("active") == 0) return;
    CHECK(loaded.at("active") == entry);
    CHECK(loaded.at("active").etag == std::optional<std::string>("W/\"abc123\""));
}

TEST(Cache, LoadAllReturnsEveryGroup) {
    TemporaryRoot root;
    const CacheStore store(root.path);
    store.save("active", fixtures::issDocument(), meta("active"));
    store.save("stations", fixtures::issDocument(), meta("stations"));

    const CacheStore::LoadedAll all = store.loadAll();
    CHECK_EQ(all.texts.size(), size_t(2));
    CHECK_EQ(all.meta.size(), size_t(2));
}

TEST(Cache, SaveReplacesExistingText) {
    TemporaryRoot root;
    const CacheStore store(root.path);
    store.save("active", "old", meta("active"));
    store.save("active", "new", meta("active"));
    CHECK(store.loadText("active") == std::optional<std::string>("new"));
}

TEST(Cache, CorruptMetaYieldsEmptyMap) {
    TemporaryRoot root;
    const CacheStore store(root.path);
    fsutil::createDirectories(root.path);
    fsutil::writeFileAtomic(root.path / "meta.json", "not json", nullptr);

    CHECK(store.loadMeta().empty());
}

TEST(Cache, MissingMetaYieldsEmptyMap) {
    TemporaryRoot root;
    CHECK(CacheStore(root.path).loadMeta().empty());
}

TEST(Cache, ClearRemovesEverything) {
    TemporaryRoot root;
    const CacheStore store(root.path);
    store.save("active", fixtures::issDocument(), meta("active"));
    store.clear();

    CHECK(!store.loadText("active").has_value());
    CHECK(store.loadMeta().empty());
    CHECK_EQ(store.diskUsage(), uintmax_t(0));
}

TEST(Cache, DiskUsageGrowsWithContent) {
    TemporaryRoot root;
    const CacheStore store(root.path);
    CHECK_EQ(store.diskUsage(), uintmax_t(0));
    store.save("active", fixtures::issDocument(), meta("active"));
    CHECK(store.diskUsage() > 0);
}

TEST(Cache, RefreshIntervalMatchesCelesTrakCadence) {
    CHECK_EQ(CacheMeta::refreshInterval, 7200.0);
    CHECK_EQ(CacheMeta::recheckInterval, 1800.0);
}

TEST(Cache, FreshEntryIsNotDue) {
    CacheMeta entry = meta("active");
    entry.lastChecked = sky::nowDate();
    CHECK(!entry.isDueForRefresh(sky::nowDate()));
}

TEST(Cache, StaleEntryIsDue) {
    CacheMeta entry = meta("active");
    entry.lastChecked = sky::nowDate() - 3600.0;
    CHECK(entry.isDueForRefresh(sky::nowDate()));
}

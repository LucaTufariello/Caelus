// CatalogService.hpp — orchestrates cache → network → fallback and produces a merged catalog.
//
// Translated from the Swift app's Data/CatalogService.swift. The two-hour
// CelesTrak window is the rate limiter: a group is only requested when its
// cache entry is older than the recheck interval (or when the user asks
// explicitly), and an "unchanged" answer costs nothing but a timestamp.

#pragma once

#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "../Support/FileSystem.hpp"
#include "CacheStore.hpp"
#include "CelesTrakClient.hpp"
#include "SatelliteCatalog.hpp"
#include "SyntheticCatalog.hpp"

namespace caelus {

class CatalogService {
public:
    struct LoadResult {
        SatelliteCatalog catalog;
        LoadDiagnostics diagnostics;
        DataProvenance provenance = DataProvenance::none;
        std::map<std::string, CacheMeta> groupMeta;
        std::vector<std::string> updatedGroups;
        Date checkedAt = 0.0;
        bool isDegraded = false;  // at least one group could not be refreshed
    };

    // A source group and the tags its records carry.
    struct Plan {
        std::string group;
        std::set<SatelliteGroup> tags;
    };

    static const std::vector<Plan>& plan();

    CatalogService(CacheStore cache, CelesTrakClient& celestrak)
        : cache_(std::move(cache)), celestrak_(celestrak) {}

    // MARK: - Cache-only load (launch path)

    // Build a catalog from whatever is on disk. Returns nullopt when nothing is cached.
    std::optional<LoadResult> loadFromCache() const;

    // MARK: - Refresh

    LoadResult refresh(bool force);

    // MARK: - Maintenance

    void clearCache() const { cache_.clear(); }
    uintmax_t diskUsage() const { return cache_.diskUsage(); }
    const fsutil::path& cacheRoot() const { return cache_.root(); }

    // Assembly is exposed for tests and for callers that already hold texts.
    static LoadResult assemble(const std::map<std::string, std::string>& texts,
                               const std::map<std::string, CacheMeta>& meta,
                               const std::map<std::string, std::string>& failures,
                               const std::vector<std::string>& updated);

    static std::string describe(const std::exception& error);

private:
    CacheStore cache_;
    CelesTrakClient& celestrak_;
};

}  // namespace caelus

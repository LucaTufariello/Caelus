// SatelliteCatalog.hpp — the merged, indexed, searchable catalog.
//
// Translated from the Swift app's Data/SatelliteCatalog.swift. Sources are
// ingested as batches of records tagged by origin; records are deduplicated by
// NORAD number, keeping the freshest element set and the union of every tag.
// Everything downstream addresses satellites by their index in `records`, which
// is stable for the lifetime of a catalog.

#pragma once

#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "../Sky/TimeUtil.hpp"
#include "Models.hpp"
#include "TLEParser.hpp"

namespace caelus {

struct SatelliteCatalog {
    std::vector<SatelliteRecord> records;
    Date generatedAt = 0.0;

    // NORAD number → index in `records`.
    std::map<int, size_t> indexByID;

    // Catalog indices per tag, in display order.
    std::map<SatelliteGroup, std::vector<size_t>> indicesByGroup;

    // Catalog indices per *render* group — each satellite appears exactly once.
    std::map<SatelliteGroup, std::vector<size_t>> renderIndices;

    SatelliteCatalog() = default;
    explicit SatelliteCatalog(std::vector<SatelliteRecord> records, Date generatedAt = 0.0);

    static SatelliteCatalog empty() { return SatelliteCatalog(); }

    size_t count() const { return records.size(); }

    // MARK: - Lookup

    const SatelliteRecord* record(int id) const;
    std::optional<size_t> index(int id) const;
    size_t countIn(SatelliteGroup group) const;

    // MARK: - Search

    // Ranked indices for a query, already filtered by group and favourites. An
    // empty query returns the whole filtered set in catalog (name) order.
    std::vector<size_t> search(const std::string& query,
                               const std::set<SatelliteGroup>& groups,
                               bool favoritesOnly, const std::set<int>& favorites,
                               size_t limit = 20000) const;

    // Higher is better; 0 means no match.
    static int score(const std::string& key, const std::string& needle, int id);

    // MARK: - Assembly

    // One source's contribution: parsed records plus the tags they carry.
    struct Batch {
        std::string group;
        std::vector<SatelliteRecord> records;
        std::set<SatelliteGroup> tags;
        std::vector<TLEParser::Failure> failures;
    };

    // Defined after the class: a catalog cannot contain itself by value while
    // it is still incomplete.
    struct Assembled;

    // Merge batches into a catalog.
    static Assembled assemble(const std::vector<Batch>& batches);

private:
    // Folded, lower-cased search keys parallel to `records`.
    std::vector<std::string> searchKeys_;
};

struct SatelliteCatalog::Assembled {
    SatelliteCatalog catalog;
    LoadDiagnostics diagnostics;
};

// Case-, width- and diacritic-insensitive-ish form used for all matching. The
// ASCII fold matches the Swift app's `folded` for every name in the catalogs it
// ingests; combining marks are dropped for the rest.
std::string folded(const std::string& text);

// Approximates `localizedStandardCompare`: case-insensitive, numeric runs
// compared by value. Returns <0, 0 or >0.
int localizedStandardCompare(const std::string& lhs, const std::string& rhs);

// Folded, lower-cased "name norad" used for matching.
std::string searchKey(const SatelliteRecord& record);

}  // namespace caelus

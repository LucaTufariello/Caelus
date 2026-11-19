#include "CatalogService.hpp"

#include <algorithm>
#include <cctype>

#include "SatNOGSSource.hpp"

namespace caelus {

const std::vector<CatalogService::Plan>& CatalogService::plan() {
    static const std::vector<Plan> plans = [] {
        std::vector<Plan> result;
        result.push_back(Plan{"active", {}});
        for (SatelliteGroup group : alwaysFetchedGroups()) {
            const auto celestrak = celestrakGroup(group);
            if (!celestrak) continue;
            result.push_back(Plan{*celestrak, {group}});
        }
        return result;
    }();
    return plans;
}

std::optional<CatalogService::LoadResult> CatalogService::loadFromCache() const {
    // Synthetic mode never reads the cache: the whole point is a catalog of
    // known size, independent of what happens to be on disk.
    if (SyntheticCatalog::isEnabled()) return std::nullopt;

    const CacheStore::LoadedAll all = cache_.loadAll();
    if (all.texts.empty()) return std::nullopt;

    LoadResult result = assemble(all.texts, all.meta, {}, {});
    if (result.catalog.count() == 0) return std::nullopt;
    return result;
}

CatalogService::LoadResult CatalogService::refresh(bool force) {
    if (SyntheticCatalog::isEnabled()) {
        SyntheticCatalog::Made made = SyntheticCatalog::make(SyntheticCatalog::requestedCount());

        LoadResult result;
        result.catalog = std::move(made.catalog);
        result.diagnostics = made.diagnostics;
        result.provenance = DataProvenance::synthetic;
        result.checkedAt = sky::nowDate();
        result.isDegraded = false;
        return result;
    }

    const Date now = sky::nowDate();
    std::map<std::string, CacheMeta> meta = cache_.loadMeta();
    std::map<std::string, std::string> texts;
    std::map<std::string, std::string> failures;
    std::vector<std::string> updated;
    bool usedSatNOGS = false;

    for (const Plan& entry : plan()) {
        if (auto cached = cache_.loadText(entry.group)) texts[entry.group] = std::move(*cached);
    }

    // Which groups are worth asking about?
    std::vector<std::string> due;
    for (const Plan& entry : plan()) {
        if (force) {
            due.push_back(entry.group);
            continue;
        }
        const auto found = meta.find(entry.group);
        if (found == meta.end() || found->second.isDueForRefresh(now)) {
            due.push_back(entry.group);
        }
    }

    // Groups are fetched one after another: the client keeps per-group backoff
    // and ETag state that the Swift actor also serialised.
    for (const std::string& group : due) {
        try {
            const FetchOutcome outcome = celestrak_.fetch(group);
            switch (outcome.kind) {
                case FetchOutcome::Kind::updated: {
                    texts[group] = outcome.text;
                    updated.push_back(group);
                    const int count =
                        static_cast<int>(TLEParser::parse(outcome.text, {}).records.size());
                    CacheMeta entry;
                    entry.group = group;
                    entry.fetchedAt = sky::nowDate();
                    entry.lastChecked = entry.fetchedAt;
                    entry.count = count;
                    if (const auto existing = meta.find(group); existing != meta.end()) {
                        entry.etag = existing->second.etag;
                    }
                    meta[group] = entry;
                    try {
                        cache_.save(group, outcome.text, entry);
                    } catch (...) {
                        // A failed cache write must not fail the refresh.
                    }
                    break;
                }

                case FetchOutcome::Kind::unchanged: {
                    if (texts.find(group) != texts.end()) {
                        CacheMeta& entry = meta[group];
                        entry.lastChecked = sky::nowDate();
                        try {
                            cache_.writeMeta(meta);
                        } catch (...) {
                        }
                    } else {
                        // CelesTrak believes we already have this group, but the
                        // cache is empty (cleared, or a fresh container).
                        failures[group] = "cached copy missing";
                    }
                    break;
                }
            }
        } catch (const std::exception& error) {
            failures[group] = describe(error);
        }
    }

    // If the base catalog is missing entirely, try SatNOGS once. The text is
    // cached like any other group so an offline relaunch still has a catalog.
    if (texts.find("active") == texts.end()) {
        try {
            const std::string fallback = SatNOGSSource::fetchTLE(celestrak_.http());
            texts["satnogs"] = fallback;
            usedSatNOGS = true;
            const int count = static_cast<int>(TLEParser::parse(fallback, {}).records.size());
            CacheMeta entry;
            entry.group = "satnogs";
            entry.fetchedAt = sky::nowDate();
            entry.lastChecked = entry.fetchedAt;
            entry.count = count;
            meta["satnogs"] = entry;
            try {
                cache_.save("satnogs", fallback, entry);
            } catch (...) {
            }
        } catch (...) {
            // The fallback is best-effort; the caller reports the failures above.
        }
    }

    // Starlink is normally tagged by name inside `active`; only fetch the
    // dedicated group when that did not yield a plausible constellation.
    int starlinkFromBase = 0;
    if (const auto active = texts.find("active"); active != texts.end()) {
        for (const std::string& line : splitLines(active->second)) {
            std::string upper = line;
            for (char& c : upper) {
                c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
            }
            if (upper.rfind("STARLINK", 0) == 0) ++starlinkFromBase;
        }
    }

    if (starlinkFromBase < 5000 && texts.find("starlink") == texts.end()) {
        try {
            const FetchOutcome outcome = celestrak_.fetch("starlink");
            if (outcome.kind == FetchOutcome::Kind::updated) {
                texts["starlink"] = outcome.text;
                updated.push_back("starlink");
                const int count =
                    static_cast<int>(TLEParser::parse(outcome.text, {}).records.size());
                CacheMeta entry;
                entry.group = "starlink";
                entry.fetchedAt = sky::nowDate();
                entry.lastChecked = entry.fetchedAt;
                entry.count = count;
                meta["starlink"] = entry;
                try {
                    cache_.save("starlink", outcome.text, entry);
                } catch (...) {
                }
            }
        } catch (...) {
        }
    }

    LoadResult result = assemble(texts, meta, failures, updated);
    if (usedSatNOGS) result.provenance = DataProvenance::satnogs;
    result.isDegraded = !failures.empty();
    return result;
}

CatalogService::LoadResult CatalogService::assemble(
    const std::map<std::string, std::string>& texts,
    const std::map<std::string, CacheMeta>& meta,
    const std::map<std::string, std::string>& failures,
    const std::vector<std::string>& updated) {
    std::vector<SatelliteCatalog::Batch> batches;

    for (const Plan& entry : plan()) {
        const auto found = texts.find(entry.group);
        if (found == texts.end()) continue;
        const TLEParser::Result parsed = TLEParser::parse(found->second, entry.tags);
        batches.push_back(
            SatelliteCatalog::Batch{entry.group, parsed.records, entry.tags, parsed.failures});
    }

    if (const auto starlink = texts.find("starlink"); starlink != texts.end()) {
        const TLEParser::Result parsed =
            TLEParser::parse(starlink->second, {SatelliteGroup::starlink});
        batches.push_back(SatelliteCatalog::Batch{"starlink", parsed.records,
                                                  {SatelliteGroup::starlink},
                                                  parsed.failures});
    }

    if (const auto satnogs = texts.find("satnogs"); satnogs != texts.end()) {
        const TLEParser::Result parsed = TLEParser::parse(satnogs->second, {});
        batches.push_back(
            SatelliteCatalog::Batch{"satnogs", parsed.records, {}, parsed.failures});
    }

    SatelliteCatalog::Assembled assembled = SatelliteCatalog::assemble(batches);

    LoadDiagnostics diagnostics = assembled.diagnostics;
    if (!failures.empty()) {
        for (const auto& entry : failures) diagnostics.failedGroups.push_back(entry.first);
        std::sort(diagnostics.failedGroups.begin(), diagnostics.failedGroups.end());
        for (const auto& entry : failures) {
            diagnostics.messages.push_back(entry.first + ": " + entry.second);
        }
    }

    LoadResult result;
    result.catalog = std::move(assembled.catalog);
    result.diagnostics = std::move(diagnostics);
    result.provenance = updated.empty() ? DataProvenance::cache : DataProvenance::celestrak;
    result.groupMeta = meta;
    result.updatedGroups = updated;
    result.checkedAt = sky::nowDate();
    result.isDegraded = !failures.empty();
    return result;
}

std::string CatalogService::describe(const std::exception& error) {
    if (const auto* fetch = dynamic_cast<const CelesTrakClient::FetchError*>(&error)) {
        return fetch->shortDescription();
    }
    if (const auto* source = dynamic_cast<const SatNOGSSource::SourceError*>(&error)) {
        return source->shortDescription();
    }
    return error.what();
}

}  // namespace caelus

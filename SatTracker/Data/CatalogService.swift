//
//  CatalogService.swift
//  SatTracker
//
//  Orchestrates cache → network → fallback and produces a merged catalog.
//
//  The two-hour CelesTrak window is the rate limiter: a group is only requested
//  when its cache entry is older than the recheck interval (or when the user
//  asks explicitly), and an "unchanged" answer costs nothing but a timestamp.
//

import Foundation

actor CatalogService {

    struct LoadResult: Sendable {
        var catalog: SatelliteCatalog
        var diagnostics: LoadDiagnostics
        var provenance: DataProvenance
        var groupMeta: [String: CacheMeta]
        var updatedGroups: [String]
        var checkedAt: Date
        /// True when at least one group could not be refreshed.
        var isDegraded: Bool
    }

    /// A source group and the tags its records carry.
    private struct Plan: Sendable {
        let group: String
        let tags: Set<SatelliteGroup>
    }

    private static let plan: [Plan] = {
        var plan: [Plan] = [Plan(group: "active", tags: [])]
        plan += SatelliteGroup.alwaysFetched.compactMap { group in
            guard let celestrak = group.celestrakGroup else { return nil }
            return Plan(group: celestrak, tags: [group])
        }
        return plan
    }()

    private let cache: CacheStore
    private let celestrak: CelesTrakClient

    init(cache: CacheStore = .applicationDefault(), celestrak: CelesTrakClient = CelesTrakClient()) {
        self.cache = cache
        self.celestrak = celestrak
    }

    // MARK: - Cache-only load (launch path)

    /// Build a catalog from whatever is on disk. Returns nil when nothing is cached.
    nonisolated func loadFromCache() -> LoadResult? {
        // Synthetic mode never reads the cache: the whole point is a catalog of
        // known size, independent of what happens to be on disk.
        guard !SyntheticCatalog.isEnabled else { return nil }
        let (texts, meta) = cache.loadAll()
        guard !texts.isEmpty else { return nil }
        let result = Self.assemble(texts: texts, meta: meta, failures: [:], updated: [])
        guard result.catalog.count > 0 else { return nil }
        return result
    }

    // MARK: - Refresh

    func refresh(force: Bool) async -> LoadResult {
        if SyntheticCatalog.isEnabled {
            let (catalog, diagnostics) = SyntheticCatalog.make(count: SyntheticCatalog.requestedCount)
            return LoadResult(catalog: catalog,
                              diagnostics: diagnostics,
                              provenance: .synthetic,
                              groupMeta: [:],
                              updatedGroups: [],
                              checkedAt: Date(),
                              isDegraded: false)
        }

        var meta = cache.loadMeta()
        var texts: [String: String] = [:]
        var failures: [String: String] = [:]
        var updated: [String] = []
        var usedSatNOGS = false

        for plan in Self.plan {
            if let cached = cache.loadText(group: plan.group) { texts[plan.group] = cached }
        }

        // Which groups are worth asking about?
        let due = Self.plan.filter { plan in
            if force { return true }
            guard let entry = meta[plan.group] else { return true }
            return entry.isDueForRefresh
        }

        if !due.isEmpty {
            let outcomes = await fetchConcurrently(due.map(\.group))
            for (group, outcome) in outcomes {
                switch outcome {
                case .success(.updated(let text)):
                    texts[group] = text
                    updated.append(group)
                    let count = TLEParser.parse(text, groups: []).records.count
                    let entry = CacheMeta(group: group,
                                          fetchedAt: Date(),
                                          lastChecked: Date(),
                                          count: count,
                                          etag: meta[group]?.etag)
                    meta[group] = entry
                    try? cache.save(group: group, text: text, meta: entry)

                case .success(.unchanged(let group)):
                    if texts[group] != nil {
                        meta[group]?.lastChecked = Date()
                        if var entry = meta[group] {
                            entry.lastChecked = Date()
                            meta[group] = entry
                            try? cache.writeMeta(meta)
                        }
                    } else {
                        // CelesTrak believes we already have this group, but the
                        // cache is empty (cleared, or a fresh container). Nothing
                        // to show unless the fallback can help.
                        failures[group] = "cached copy missing"
                    }

                case .failure(let error):
                    failures[group] = Self.describe(error)
                    if texts[group] == nil {
                        // Nothing cached for this group; the fallback may still
                        // provide a usable base catalog.
                    }
                }
            }
        }

        // If the base catalog is missing entirely, try SatNOGS once. The text is
        // cached like any other group so an offline relaunch still has a catalog.
        if texts["active"] == nil {
            if let fallback = try? await SatNOGSSource.fetchTLE() {
                texts["satnogs"] = fallback
                usedSatNOGS = true
                let count = TLEParser.parse(fallback, groups: []).records.count
                let entry = CacheMeta(group: "satnogs", fetchedAt: Date(), lastChecked: Date(),
                                      count: count, etag: nil)
                meta["satnogs"] = entry
                try? cache.save(group: "satnogs", text: fallback, meta: entry)
            }
        }

        // Starlink is normally tagged by name inside `active`; only fetch the
        // dedicated group when that did not yield a plausible constellation.
        let starlinkFromBase = texts["active"].map { text in
            text.split(whereSeparator: \.isNewline).reduce(into: 0) { count, line in
                if line.uppercased().hasPrefix("STARLINK") { count += 1 }
            }
        } ?? 0

        if starlinkFromBase < 5_000, texts["starlink"] == nil {
            if case .updated(let text)? = try? await celestrak.fetch(group: "starlink") {
                texts["starlink"] = text
                updated.append("starlink")
                let count = TLEParser.parse(text, groups: []).records.count
                let entry = CacheMeta(group: "starlink", fetchedAt: Date(), lastChecked: Date(),
                                      count: count, etag: nil)
                meta["starlink"] = entry
                try? cache.save(group: "starlink", text: text, meta: entry)
            }
        }

        var result = Self.assemble(texts: texts, meta: meta, failures: failures, updated: updated)
        if usedSatNOGS { result.provenance = .satnogs }
        result.isDegraded = !failures.isEmpty
        return result
    }

    // MARK: - Fetching

    private func fetchConcurrently(_ groups: [String]) async -> [(String, Result<FetchOutcome, Error>)] {
        let client = celestrak
        return await withTaskGroup(of: (String, Result<FetchOutcome, Error>).self) { taskGroup in
            for group in groups {
                taskGroup.addTask {
                    do {
                        return (group, .success(try await client.fetch(group: group)))
                    } catch {
                        return (group, .failure(error))
                    }
                }
            }
            var results: [(String, Result<FetchOutcome, Error>)] = []
            for await result in taskGroup { results.append(result) }
            return results
        }
    }

    // MARK: - Assembly

    private static func assemble(texts: [String: String],
                                 meta: [String: CacheMeta],
                                 failures: [String: String],
                                 updated: [String]) -> LoadResult {
        var batches: [SatelliteCatalog.Batch] = []

        for plan in plan {
            guard let text = texts[plan.group] else { continue }
            let parsed = TLEParser.parse(text, groups: plan.tags)
            batches.append(.init(group: plan.group, records: parsed.records,
                                 tags: plan.tags, failures: parsed.failures))
        }

        if let starlink = texts["starlink"] {
            let parsed = TLEParser.parse(starlink, groups: [.starlink])
            batches.append(.init(group: "starlink", records: parsed.records,
                                 tags: [.starlink], failures: parsed.failures))
        }

        if let satnogs = texts["satnogs"] {
            let parsed = TLEParser.parse(satnogs, groups: [])
            batches.append(.init(group: "satnogs", records: parsed.records,
                                 tags: [], failures: parsed.failures))
        }

        let (catalog, diagnostics) = SatelliteCatalog.assemble(batches: batches)

        var merged = diagnostics
        if !failures.isEmpty {
            merged.failedGroups = failures.keys.sorted()
            for (group, reason) in failures.sorted(by: { $0.key < $1.key }) {
                merged.messages.append("\(group): \(reason)")
            }
        }

        let provenance: DataProvenance = updated.isEmpty ? .cache : .celestrak

        return LoadResult(catalog: catalog,
                          diagnostics: merged,
                          provenance: provenance,
                          groupMeta: meta,
                          updatedGroups: updated,
                          checkedAt: Date(),
                          isDegraded: !failures.isEmpty)
    }

    private static func describe(_ error: Error) -> String {
        if let fetch = error as? CelesTrakClient.FetchError { return fetch.shortDescription }
        if let source = error as? SatNOGSSource.SourceError { return source.shortDescription }
        return error.localizedDescription
    }

    // MARK: - Maintenance

    func clearCache() throws {
        try cache.clear()
    }

    nonisolated func diskUsage() -> Int { cache.diskUsage() }

    nonisolated var cacheRoot: URL { cache.root }
}

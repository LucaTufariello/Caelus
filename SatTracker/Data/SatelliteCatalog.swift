//
//  SatelliteCatalog.swift
//  SatTracker
//
//  The merged, indexed, searchable catalog.
//
//  Sources are ingested as batches of records tagged by origin; records are
//  deduplicated by NORAD number, keeping the freshest element set and the union
//  of every tag. Everything downstream addresses satellites by their index in
//  `records`, which is stable for the lifetime of a catalog.
//

import Foundation
import SatelliteKit

struct SatelliteCatalog: Sendable {

    let records: [SatelliteRecord]
    let generatedAt: Date

    /// NORAD number → index in `records`.
    let indexByID: [Int: Int]

    /// Catalog indices per tag, in display order.
    let indicesByGroup: [SatelliteGroup: [Int]]

    /// Catalog indices per *render* group — each satellite appears exactly once.
    let renderIndices: [SatelliteGroup: [Int]]

    /// Folded, lower-cased search keys parallel to `records`.
    private let searchKeys: [String]

    var count: Int { records.count }

    // MARK: - Init

    init(records: [SatelliteRecord], generatedAt: Date = Date()) {
        self.records = records
        self.generatedAt = generatedAt

        var byID: [Int: Int] = [:]
        byID.reserveCapacity(records.count)
        var byGroup: [SatelliteGroup: [Int]] = [:]
        var render: [SatelliteGroup: [Int]] = [:]
        var keys: [String] = []
        keys.reserveCapacity(records.count)

        for (index, record) in records.enumerated() {
            byID[record.id] = index
            for group in record.groups {
                byGroup[group, default: []].append(index)
            }
            render[record.renderGroup, default: []].append(index)
            keys.append(record.searchKey)
        }

        self.indexByID = byID
        self.indicesByGroup = byGroup
        self.renderIndices = render
        self.searchKeys = keys
    }

    static let empty = SatelliteCatalog(records: [])

    // MARK: - Lookup

    func record(id: Int) -> SatelliteRecord? {
        guard let index = indexByID[id] else { return nil }
        return records[index]
    }

    func index(id: Int) -> Int? { indexByID[id] }

    func count(in group: SatelliteGroup) -> Int {
        indicesByGroup[group]?.count ?? 0
    }

    // MARK: - Search

    /// Ranked indices for a query, already filtered by group and favourites.
    ///
    /// An empty query returns the whole filtered set in catalog (name) order.
    func search(_ query: String,
                groups: Set<SatelliteGroup>,
                favoritesOnly: Bool,
                favorites: Set<Int>,
                limit: Int = 20_000) -> [Int] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = trimmed.folded

        // Fast path: no text query — walk the catalog in order.
        if needle.isEmpty {
            var result: [Int] = []
            result.reserveCapacity(min(limit, records.count))
            for index in records.indices {
                let record = records[index]
                if !groups.isEmpty, record.groups.isDisjoint(with: groups) { continue }
                if favoritesOnly, !favorites.contains(record.id) { continue }
                result.append(index)
                if result.count >= limit { break }
            }
            return result
        }

        var scored: [(index: Int, score: Int)] = []
        scored.reserveCapacity(256)

        for index in records.indices {
            let record = records[index]
            if !groups.isEmpty, record.groups.isDisjoint(with: groups) { continue }
            if favoritesOnly, !favorites.contains(record.id) { continue }

            let score = Self.score(key: searchKeys[index], needle: needle, id: record.id)
            if score > 0 { scored.append((index, score)) }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return records[lhs.index].name.localizedStandardCompare(records[rhs.index].name) == .orderedAscending
        }

        return scored.prefix(limit).map(\.index)
    }

    /// Higher is better; 0 means no match.
    private static func score(key: String, needle: String, id: Int) -> Int {
        if let numeric = Int(needle), numeric == id { return 1000 }
        if key.hasPrefix(needle) { return 500 }
        if key.contains(" " + needle) { return 300 }   // start of a later word
        if key.contains(needle) { return 100 }
        return 0
    }

    // MARK: - Assembly

    /// One source's contribution: parsed records plus the tags they carry.
    struct Batch: Sendable {
        var group: String
        var records: [SatelliteRecord]
        var tags: Set<SatelliteGroup>
        var failures: [TLEParser.Failure]
    }

    /// Merge batches into a catalog.
    ///
    /// - Deduplicates by NORAD number, preferring the newest epoch.
    /// - Unions tags across sources.
    /// - Applies the name-prefix Starlink rule.
    /// - Tags anything left untagged as `.other`.
    /// - Sorts by name so indices are stable and the list is predictable.
    static func assemble(batches: [Batch]) -> (catalog: SatelliteCatalog, diagnostics: LoadDiagnostics) {
        var diagnostics = LoadDiagnostics()
        var byID: [Int: SatelliteRecord] = [:]
        byID.reserveCapacity(18_000)

        for batch in batches {
            diagnostics.parseFailures += batch.failures.count
            if !batch.failures.isEmpty {
                let sample = batch.failures.prefix(3).map { "\($0.name): \($0.reason)" }
                diagnostics.messages.append(contentsOf: sample.map { "\(batch.group) — \($0)" })
            }

            for record in batch.records {
                if var existing = byID[record.id] {
                    diagnostics.duplicateRecords += 1
                    let merged = existing.groups.union(record.groups)
                    if record.epoch > existing.epoch { existing = record }
                    existing = SatelliteRecord(id: existing.id,
                                               name: existing.name,
                                               elements: existing.elements,
                                               groups: merged,
                                               epoch: existing.epoch)
                    byID[record.id] = existing
                } else {
                    byID[record.id] = record
                }
            }
        }

        // Name-prefix tagging for Starlink, which is far too large to fetch twice.
        var records = byID.values.map { record -> SatelliteRecord in
            var groups = record.groups
            if record.name.uppercased().hasPrefix("STARLINK") { groups.insert(.starlink) }
            if groups.isEmpty { groups.insert(.other) }
            if groups.count > 1 { groups.remove(.other) }
            guard groups != record.groups else { return record }
            return SatelliteRecord(id: record.id,
                                   name: record.name,
                                   elements: record.elements,
                                   groups: groups,
                                   epoch: record.epoch)
        }

        records.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let catalog = SatelliteCatalog(records: records)
        return (catalog, diagnostics)
    }
}

// MARK: - Search key

extension SatelliteRecord {
    /// Folded, lower-cased "name norad" used for matching.
    var searchKey: String {
        "\(name) \(id)".folded
    }
}

extension String {
    /// Case-, width- and diacritic-insensitive form used for all matching.
    var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
    }
}

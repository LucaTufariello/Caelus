//
//  CatalogTests.swift
//  CaelusTests
//

import XCTest
@testable import Caelus

final class CatalogTests: XCTestCase {

    private func batch(_ text: String,
                       group: String,
                       tags: Set<SatelliteGroup>) -> SatelliteCatalog.Batch {
        let parsed = TLEParser.parse(text, groups: tags)
        return .init(group: group, records: parsed.records, tags: tags, failures: parsed.failures)
    }

    // MARK: - Deduplication

    func testDuplicateRecordsMergeTagsAndKeepNewestEpoch() throws {
        // Same object served by two groups with different tags.
        let stations = batch(TLEFixtures.issDocument, group: "stations", tags: [.stations])
        let science = batch(TLEFixtures.issDocument, group: "science", tags: [.science])

        let (catalog, diagnostics) = SatelliteCatalog.assemble(batches: [stations, science])

        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(diagnostics.duplicateRecords, 1)

        let record = try XCTUnwrap(catalog.records.first)
        XCTAssertEqual(record.groups, [.stations, .science])
        // Render priority puts stations first.
        XCTAssertEqual(record.renderGroup, .stations)
    }

    func testRenderIndicesCoverEveryRecordExactlyOnce() {
        let text = TLEFixtures.syntheticDocument(count: 40)
        let (catalog, _) = SatelliteCatalog.assemble(batches: [
            batch(text, group: "active", tags: []),
        ])

        let total = catalog.renderIndices.values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, catalog.count)

        let flattened = Set(catalog.renderIndices.values.flatMap { $0 })
        XCTAssertEqual(flattened.count, catalog.count)
    }

    // MARK: - Tagging

    func testStarlinkIsTaggedByNamePrefix() throws {
        let document = TLEFixtures.document(id: 44_713, name: "STARLINK-1007", raan: 10)
        let (catalog, _) = SatelliteCatalog.assemble(batches: [
            batch(document, group: "active", tags: []),
        ])

        let record = try XCTUnwrap(catalog.records.first)
        XCTAssertTrue(record.groups.contains(.starlink))
        XCTAssertEqual(record.renderGroup, .starlink)
    }

    func testUntaggedRecordsBecomeOther() throws {
        let document = TLEFixtures.document(id: 90_001, name: "SOMETHING", raan: 10)
        let (catalog, _) = SatelliteCatalog.assemble(batches: [
            batch(document, group: "active", tags: []),
        ])

        let record = try XCTUnwrap(catalog.records.first)
        XCTAssertEqual(record.groups, [.other])
        XCTAssertEqual(record.renderGroup, .other)
    }

    func testOtherIsDroppedWhenARealTagExists() throws {
        let document = TLEFixtures.document(id: 90_002, name: "WEATHER BIRD", raan: 10)
        let (catalog, _) = SatelliteCatalog.assemble(batches: [
            batch(document, group: "active", tags: []),
            batch(document, group: "weather", tags: [.weather]),
        ])

        let record = try XCTUnwrap(catalog.records.first)
        XCTAssertFalse(record.groups.contains(.other))
        XCTAssertEqual(record.renderGroup, .weather)
    }

    // MARK: - Ordering and lookup

    func testRecordsAreSortedByName() {
        let text = TLEFixtures.document(id: 30_003, name: "ZULU", raan: 1)
            + TLEFixtures.document(id: 10_001, name: "ALPHA", raan: 2)
            + TLEFixtures.document(id: 20_002, name: "MIKE", raan: 3)

        let (catalog, _) = SatelliteCatalog.assemble(batches: [
            batch(text, group: "active", tags: []),
        ])

        XCTAssertEqual(catalog.records.map(\.name), ["ALPHA", "MIKE", "ZULU"])
    }

    func testLookupByID() {
        let (catalog, _) = SatelliteCatalog.assemble(batches: [
            batch(TLEFixtures.issDocument, group: "active", tags: []),
        ])

        let index = catalog.index(id: 25544)
        XCTAssertNotNil(index)
        XCTAssertEqual(catalog.records[index!].name, "ISS (ZARYA)")
        XCTAssertNil(catalog.index(id: 1))
    }

    // MARK: - Search

    private func makeSearchCatalog() -> SatelliteCatalog {
        let text = TLEFixtures.document(id: 25544, name: "ISS (ZARYA)", raan: 10)
            + TLEFixtures.document(id: 44_713, name: "STARLINK-1007", raan: 20)
            + TLEFixtures.document(id: 44_714, name: "STARLINK-1008", raan: 30)
            + TLEFixtures.document(id: 20_001, name: "NOAA 19", raan: 40)

        let parsed = TLEParser.parse(text, groups: [])
        return SatelliteCatalog.assemble(batches: [
            .init(group: "active", records: parsed.records, tags: [], failures: []),
        ]).catalog
    }

    func testSearchByNoradIDRanksExactMatchFirst() {
        let catalog = makeSearchCatalog()
        let results = catalog.search("25544", groups: [], favoritesOnly: false, favorites: [])
        XCTAssertEqual(results.first.map { catalog.records[$0].id }, 25544)
    }

    func testSearchByNamePrefix() {
        let catalog = makeSearchCatalog()
        let results = catalog.search("ISS", groups: [], favoritesOnly: false, favorites: [])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(catalog.records[results[0]].name, "ISS (ZARYA)")
    }

    func testSearchIsCaseAndDiacriticInsensitive() {
        let catalog = makeSearchCatalog()
        XCTAssertEqual(catalog.search("starlink", groups: [], favoritesOnly: false, favorites: []).count, 2)
        XCTAssertEqual(catalog.search("STARLINK", groups: [], favoritesOnly: false, favorites: []).count, 2)
    }

    func testSearchRanksPrefixAboveSubstring() {
        let catalog = makeSearchCatalog()
        let results = catalog.search("1007", groups: [], favoritesOnly: false, favorites: [])
        XCTAssertEqual(catalog.records[results[0]].id, 44_713)
    }

    func testSearchRespectsGroupFilter() {
        let catalog = makeSearchCatalog()
        let results = catalog.search("", groups: [.starlink], favoritesOnly: false, favorites: [])
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { catalog.records[$0].name.hasPrefix("STARLINK") })
    }

    func testSearchRespectsFavoritesOnly() {
        let catalog = makeSearchCatalog()
        let results = catalog.search("", groups: [], favoritesOnly: true, favorites: [25544])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(catalog.records[results[0]].id, 25544)
    }

    func testEmptyQueryReturnsEverythingInOrder() {
        let catalog = makeSearchCatalog()
        let results = catalog.search("", groups: [], favoritesOnly: false, favorites: [])
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results, results.sorted())
    }

    func testNoMatchReturnsEmpty() {
        let catalog = makeSearchCatalog()
        XCTAssertTrue(catalog.search("nothing here", groups: [], favoritesOnly: false, favorites: []).isEmpty)
    }

    // MARK: - Diagnostics

    func testParseFailuresAreCounted() {
        let broken = "BROKEN\n\(TLEFixtures.issLine1)\n"
        let (_, diagnostics) = SatelliteCatalog.assemble(batches: [
            batch(broken, group: "active", tags: []),
        ])
        XCTAssertEqual(diagnostics.parseFailures, 1)
        XCTAssertFalse(diagnostics.isEmpty)
    }
}

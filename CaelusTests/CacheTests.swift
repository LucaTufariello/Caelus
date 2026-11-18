//
//  CacheTests.swift
//  CaelusTests
//

import XCTest
@testable import Caelus

final class CacheTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaelusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func meta(_ group: String, count: Int = 1) -> CacheMeta {
        CacheMeta(group: group, fetchedAt: Date(), lastChecked: Date(), count: count, etag: nil)
    }

    // MARK: - Round trip

    func testSaveAndLoadText() throws {
        let store = CacheStore(root: root)
        try store.save(group: "active", text: TLEFixtures.issDocument, meta: meta("active"))

        XCTAssertEqual(store.loadText(group: "active"), TLEFixtures.issDocument)
        XCTAssertNil(store.loadText(group: "missing"))
    }

    func testMetaRoundTrip() throws {
        let store = CacheStore(root: root)
        try store.save(group: "active", text: TLEFixtures.issDocument, meta: meta("active", count: 1))
        try store.save(group: "stations", text: TLEFixtures.issDocument, meta: meta("stations", count: 1))

        let loaded = store.loadMeta()
        XCTAssertEqual(Set(loaded.keys), ["active", "stations"])
        XCTAssertEqual(loaded["active"]?.count, 1)
    }

    func testLoadAllReturnsEveryGroup() throws {
        let store = CacheStore(root: root)
        try store.save(group: "active", text: TLEFixtures.issDocument, meta: meta("active"))
        try store.save(group: "stations", text: TLEFixtures.issDocument, meta: meta("stations"))

        let (texts, metaMap) = store.loadAll()
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(metaMap.count, 2)
    }

    func testSaveReplacesExistingText() throws {
        let store = CacheStore(root: root)
        try store.save(group: "active", text: "old", meta: meta("active"))
        try store.save(group: "active", text: "new", meta: meta("active"))
        XCTAssertEqual(store.loadText(group: "active"), "new")
    }

    // MARK: - Resilience

    func testCorruptMetaYieldsEmptyMap() throws {
        let store = CacheStore(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("meta.json"))

        XCTAssertTrue(store.loadMeta().isEmpty)
    }

    func testMissingMetaYieldsEmptyMap() {
        XCTAssertTrue(CacheStore(root: root).loadMeta().isEmpty)
    }

    func testClearRemovesEverything() throws {
        let store = CacheStore(root: root)
        try store.save(group: "active", text: TLEFixtures.issDocument, meta: meta("active"))
        try store.clear()

        XCTAssertNil(store.loadText(group: "active"))
        XCTAssertTrue(store.loadMeta().isEmpty)
        XCTAssertEqual(store.diskUsage(), 0)
    }

    func testDiskUsageGrowsWithContent() throws {
        let store = CacheStore(root: root)
        XCTAssertEqual(store.diskUsage(), 0)
        try store.save(group: "active", text: TLEFixtures.issDocument, meta: meta("active"))
        XCTAssertGreaterThan(store.diskUsage(), 0)
    }

    // MARK: - Refresh policy

    func testRefreshIntervalMatchesCelesTrakCadence() {
        XCTAssertEqual(CacheMeta.refreshInterval, 7_200)
        XCTAssertEqual(CacheMeta.recheckInterval, 1_800)
    }

    func testFreshEntryIsNotDue() {
        var entry = meta("active")
        entry.lastChecked = Date()
        XCTAssertFalse(entry.isDueForRefresh)
    }

    func testStaleEntryIsDue() {
        var entry = meta("active")
        entry.lastChecked = Date().addingTimeInterval(-3_600)
        XCTAssertTrue(entry.isDueForRefresh)
    }
}

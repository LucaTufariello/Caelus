//
//  TLEParserTests.swift
//  SatTrackerTests
//

import XCTest
@testable import SatTracker

final class TLEParserTests: XCTestCase {

    // MARK: - Golden record

    func testParsesISS() throws {
        let result = TLEParser.parse(TLEFixtures.issDocument, groups: [.stations])

        XCTAssertEqual(result.records.count, 1)
        XCTAssertTrue(result.failures.isEmpty, "unexpected failures: \(result.failures)")

        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(record.id, 25544)
        XCTAssertEqual(record.name, "ISS (ZARYA)")
        XCTAssertEqual(record.cosparID, "1998-067A")
        XCTAssertEqual(record.groups, [.stations])
        XCTAssertEqual(record.renderGroup, .stations)

        XCTAssertEqual(record.inclinationDeg, 51.6323, accuracy: 1e-4)
        XCTAssertEqual(record.eccentricity, 0.0007326, accuracy: 1e-7)
        XCTAssertEqual(record.raanDeg, 291.9174, accuracy: 1e-4)

        // Mean motion 15.4931 rev/day → 92.94 min.
        XCTAssertEqual(record.periodMinutes, 92.94, accuracy: 0.02)
        XCTAssertEqual(record.perigeeKm, 415, accuracy: 15)
        XCTAssertEqual(record.apogeeKm, 425, accuracy: 15)
    }

    func testEpochIsParsed() throws {
        let record = try XCTUnwrap(TLEParser.parse(TLEFixtures.issDocument, groups: []).records.first)
        // 2026 day 315.33607970 → 11 November 2026, 08:03 UTC.
        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(identifier: "UTC")!, from: record.epoch)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 11)
        XCTAssertEqual(components.day, 11)
        XCTAssertEqual(components.hour, 8)
    }

    // MARK: - Checksums

    func testCorruptedChecksumIsRejected() {
        var line = TLEFixtures.issLine1
        // Flip the final checksum digit.
        let last = line.removeLast()
        line.append(last == "6" ? "7" : "6")

        let result = TLEParser.parse("ISS\n\(line)\n\(TLEFixtures.issLine2)\n", groups: [])
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.reason, "line 1 checksum")
    }

    func testCorruptedDigitIsRejected() {
        // Change a digit in place and leave the original checksum: the parser
        // must notice the mismatch rather than trusting the line.
        var characters = Array(TLEFixtures.issLine1)
        characters[53] = "9"
        let broken = String(characters)

        let result = TLEParser.parse("ISS\n\(broken)\n\(TLEFixtures.issLine2)\n", groups: [])
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.failures.first?.reason, "line 1 checksum")
    }

    func testRecomputedChecksumIsAccepted() {
        let body = String(TLEFixtures.issLine1.prefix(68))
        let fixed = TLEFixtures.tleLine(body, [(53, " 17018-3")])
        let line2 = TLEFixtures.issLine2
        let result = TLEParser.parse("ISS\n\(fixed)\n\(line2)\n", groups: [])
        XCTAssertEqual(result.records.count, 1)
    }

    // MARK: - Structural failures

    func testMissingSecondLineIsReported() {
        let result = TLEParser.parse("ORPHAN\n\(TLEFixtures.issLine1)\n", groups: [])
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.reason, "truncated record")
    }

    func testMismatchedNoradIDsAreRejected() {
        let document = "MISMATCH\n\(TLEFixtures.issLine1)\n\(TLEFixtures.poiskLine2)\n"
        let result = TLEParser.parse(document, groups: [])
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.failures.first?.reason, "NORAD id mismatch (25544 / 36086)")
    }

    func testEmptyDocumentProducesNothing() {
        let result = TLEParser.parse("", groups: [])
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
    }

    // MARK: - Alpha-5

    func testAlpha5NoradIDs() {
        func id(_ field: String) -> Int? {
            TLEParser.noradID(Array("1 \(field)".utf8))
        }
        XCTAssertEqual(id("25544"), 25544)
        XCTAssertEqual(id("A0001"), 100_001)
        XCTAssertEqual(id("H9999"), 179_999)
        XCTAssertEqual(id("J0000"), 180_000)
        XCTAssertEqual(id("N9999"), 229_999)
        XCTAssertEqual(id("P0000"), 230_000)
        XCTAssertEqual(id("Z9999"), 339_999)
        // "I" and "O" are deliberately excluded from the alphabet.
        XCTAssertNil(id("I0000"))
        XCTAssertNil(id("O0000"))
    }

    // MARK: - Names

    func testThreeLineElementNamePrefixIsStripped() {
        XCTAssertEqual(TLEParser.normaliseName("0 ISS (ZARYA)"), "ISS (ZARYA)")
        XCTAssertEqual(TLEParser.normaliseName("  ISS (ZARYA)  "), "ISS (ZARYA)")
    }

    func testLongNamesAreTruncated() {
        let long = String(repeating: "A", count: 40)
        XCTAssertEqual(TLEParser.normaliseName(long).count, 24)
    }

    // MARK: - Batch behaviour

    func testMultipleRecordsAndPartialFailure() {
        let document = TLEFixtures.issDocument
            + "BROKEN\n\(TLEFixtures.poiskLine1)\nnot a line 2\n"
            + "POISK\n\(TLEFixtures.poiskLine1)\n\(TLEFixtures.poiskLine2)\n"

        let result = TLEParser.parse(document, groups: [.stations])
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(Set(result.records.map(\.id)), [25544, 36086])
    }

    func testGeneratedCatalogIsFullyValid() {
        let text = TLEFixtures.syntheticDocument(count: 500)
        let result = TLEParser.parse(text, groups: [])
        XCTAssertEqual(result.records.count, 500)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(Set(result.records.map(\.id)).count, 500)
    }
}

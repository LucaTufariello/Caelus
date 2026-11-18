//
//  TLEParser.swift
//  Caelus
//
//  Turns raw CelesTrak / SatNOGS text into `SatelliteRecord`s.
//
//  SatelliteKit's `Elements(_:_:_:)` initialiser force-unwraps most of its
//  numeric fields, so a malformed line would crash the process rather than
//  throw. Every record is therefore validated structurally here first, and
//  failures are collected instead of aborting the batch.
//

import Foundation
import SatelliteKit

enum TLEParser {

    struct Failure: Sendable, Equatable {
        let name: String
        let reason: String
    }

    struct Result: Sendable {
        var records: [SatelliteRecord] = []
        var failures: [Failure] = []
    }

    /// Parse a three-line-element document.
    ///
    /// - Parameters:
    ///   - text: The raw body, three lines per object (name, line 1, line 2).
    ///   - groups: Tags applied to every record produced.
    static func parse(_ text: String, groups: Set<SatelliteGroup>) -> Result {
        var result = Result()

        var pendingName: String?
        var pendingLine1: String?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty { continue }

            if line.hasPrefix("1 ") {
                if pendingLine1 != nil {
                    // Two line-1s in a row: the first had no line 2.
                    result.failures.append(.init(name: pendingName ?? "?", reason: "line 2 missing"))
                }
                pendingLine1 = line
                continue
            }

            if line.hasPrefix("2 ") {
                guard let line1 = pendingLine1 else {
                    result.failures.append(.init(name: pendingName ?? "?", reason: "line 2 without line 1"))
                    continue
                }
                let name = pendingName ?? ""
                do {
                    let record = try makeRecord(name: name, line1: line1, line2: line, groups: groups)
                    result.records.append(record)
                } catch {
                    result.failures.append(.init(name: name.isEmpty ? "?" : name,
                                                 reason: (error as? ParseError)?.message ?? "\(error)"))
                }
                pendingName = nil
                pendingLine1 = nil
                continue
            }

            // Anything else is a name line. Keep the most recent one.
            pendingName = normaliseName(line)
        }

        if let line1 = pendingLine1 {
            result.failures.append(.init(name: pendingName ?? "?", reason: "truncated record"))
            _ = line1
        }

        return result
    }

    // MARK: - One record

    enum ParseError: Error {
        case invalid(String)
        var message: String {
            switch self {
            case .invalid(let m): m
            }
        }
    }

    static func makeRecord(name: String,
                           line1: String,
                           line2: String,
                           groups: Set<SatelliteGroup>) throws -> SatelliteRecord {
        let b1 = Array(line1.utf8)
        let b2 = Array(line2.utf8)

        guard b1.count >= 69 else { throw ParseError.invalid("line 1 is \(b1.count) bytes") }
        guard b2.count >= 69 else { throw ParseError.invalid("line 2 is \(b2.count) bytes") }
        guard b1[0] == UInt8(ascii: "1") else { throw ParseError.invalid("line 1 does not start with '1'") }
        guard b2[0] == UInt8(ascii: "2") else { throw ParseError.invalid("line 2 does not start with '2'") }

        guard let id1 = noradID(b1), let id2 = noradID(b2) else {
            throw ParseError.invalid("unreadable NORAD id")
        }
        guard id1 == id2 else { throw ParseError.invalid("NORAD id mismatch (\(id1) / \(id2))") }

        guard checksumOK(b1) else { throw ParseError.invalid("line 1 checksum") }
        guard checksumOK(b2) else { throw ParseError.invalid("line 2 checksum") }

        // Fields SatelliteKit force-unwraps: prove they parse before handing over.
        guard let epochYear = int(b1, 18, 20),
              let epochDay = double(b1, 20, 32),
              let elementNumber = int(b1, 64, 68) else {
            throw ParseError.invalid("line 1 epoch/element number")
        }
        guard (0..<400).contains(epochDay) else { throw ParseError.invalid("epoch day \(epochDay) out of range") }
        guard let inclination = double(b2, 8, 16),
              let raan = double(b2, 17, 25),
              let eccentricity = double("0." + String(decoding: b2[26..<33], as: UTF8.self)),
              let argPerigee = double(b2, 34, 42),
              let meanAnomaly = double(b2, 43, 51),
              let meanMotion = double(b2, 52, 63),
              let revNumber = int(b2, 63, 68) else {
            throw ParseError.invalid("line 2 element fields")
        }
        guard (0...180).contains(inclination) else { throw ParseError.invalid("inclination \(inclination)") }
        guard (0.0..<1.0).contains(eccentricity) else { throw ParseError.invalid("eccentricity \(eccentricity)") }
        guard meanMotion > 0 else { throw ParseError.invalid("mean motion \(meanMotion)") }
        guard (0..<(360 * 2)).contains(raan), (0..<(360 * 2)).contains(argPerigee),
              (0..<(360 * 2)).contains(meanAnomaly) else {
            throw ParseError.invalid("angle out of range")
        }
        _ = epochYear

        let elements: Elements
        do {
            elements = try Elements(name, line1, line2)
        } catch {
            throw ParseError.invalid("\(error)")
        }

        // SatelliteKit reports a handful of fields; cross-check the ones we
        // validated so a silent mis-parse cannot slip through.
        guard Int(elements.noradIndex) == id1 else {
            throw ParseError.invalid("parsed NORAD id \(elements.noradIndex) ≠ \(id1)")
        }
        guard elements.n₀ > 0, elements.a₀ > 0 else {
            throw ParseError.invalid("degenerate orbit")
        }
        _ = elementNumber
        _ = revNumber

        let displayName = name.isEmpty ? String(id1) : name

        return SatelliteRecord(id: id1,
                               name: displayName,
                               elements: elements,
                               groups: groups,
                               epoch: Date(ds1950: elements.t₀))
    }

    // MARK: - Line-level helpers

    /// CelesTrak sometimes prefixes the name with `"0 "` (three-line-element form).
    static func normaliseName(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("0 ") { name.removeFirst(2) }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.count > 24 { name = String(name.prefix(24)) }
        return name
    }

    /// Decode columns 2…6, which may use the Alpha-5 convention.
    static func noradID(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 7 else { return nil }
        let field = Array(bytes[2..<7])
        guard let first = field.first else { return nil }

        let prefix: Int
        switch first {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            prefix = Int(first - UInt8(ascii: "0"))
        case UInt8(ascii: "A")...UInt8(ascii: "H"):
            prefix = Int(first - UInt8(ascii: "A")) + 10
        case UInt8(ascii: "J")...UInt8(ascii: "N"):
            prefix = Int(first - UInt8(ascii: "J")) + 18
        case UInt8(ascii: "P")...UInt8(ascii: "Z"):
            prefix = Int(first - UInt8(ascii: "P")) + 23
        default:
            return nil
        }
        guard let rest = Int(String(decoding: field[1...], as: UTF8.self)) else { return nil }
        return prefix * 10_000 + rest
    }

    /// Standard TLE modulo-10 checksum over columns 0…67.
    static func checksumOK(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 69 else { return false }
        var sum = 0
        for i in 0..<68 {
            let b = bytes[i]
            if b >= 48, b <= 57 { sum += Int(b - 48) }
            else if b == UInt8(ascii: "-") { sum += 1 }
        }
        guard let check = Int(String(UnicodeScalar(bytes[68]))) else { return false }
        return sum % 10 == check
    }

    private static func int(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Int? {
        guard bytes.count >= end else { return nil }
        let slice = String(decoding: bytes[start..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return Int(slice)
    }

    private static func double(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Double? {
        guard bytes.count >= end else { return nil }
        let slice = String(decoding: bytes[start..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return Double(slice)
    }

    private static func double(_ string: String) -> Double? {
        Double(string.trimmingCharacters(in: .whitespaces))
    }
}

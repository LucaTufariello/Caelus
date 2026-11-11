//
//  SyntheticCatalog.swift
//  SatTracker
//
//  A QA-only catalog generator.
//
//  The real catalog depends on CelesTrak's per-client two-hour window, which
//  makes it impossible to exercise the 16 000-object render and propagation path
//  on demand. Setting `SATTRAKER_SYNTHETIC_CATALOG=<count>` substitutes a
//  generated catalog so the performance budgets can be measured reproducibly.
//
//  These are NOT real satellites. Every surface that could be mistaken for live
//  data — the status bar, the sidebar indicator, Settings — reports SYNTHETIC in
//  the danger colour while this mode is active.
//

import Foundation
import SatelliteKit

enum SyntheticCatalog {

    /// Number of objects requested, or 0 when the mode is off.
    static var requestedCount: Int {
        guard let raw = ProcessInfo.processInfo.environment["SATTRAKER_SYNTHETIC_CATALOG"],
              let count = Int(raw), count > 0 else { return 0 }
        return min(count, 60_000)
    }

    static var isEnabled: Bool { requestedCount > 0 }

    // MARK: - Generation

    /// Build a catalog spread over plausible orbital shells.
    static func make(count: Int) -> (catalog: SatelliteCatalog, diagnostics: LoadDiagnostics) {
        var records: [SatelliteRecord] = []
        records.reserveCapacity(count)

        for index in 0..<count {
            let id = 90_000 + index
            let shell = shell(for: index, of: count)
            guard let record = record(id: id, index: index, shell: shell) else { continue }
            records.append(record)
        }

        var diagnostics = LoadDiagnostics()
        diagnostics.unpropagatable = count - records.count
        let catalog = SatelliteCatalog(records: records)
        return (catalog, diagnostics)
    }

    private struct Shell {
        let altitudeKm: Double
        let inclinationDeg: Double
        let eccentricity: Double
        let tag: SatelliteGroup
        let prefix: String
    }

    /// Roughly the real mix: mostly LEO, some navigation, a few GEO.
    private static func shell(for index: Int, of count: Int) -> Shell {
        switch index % 20 {
        case 0..<12:
            // Low Earth orbit, the bulk of the catalog.
            let altitudes: [Double] = [420, 520, 550, 570, 600, 780]
            let inclinations: [Double] = [53, 70, 97.6, 43, 28.5, 82]
            return Shell(altitudeKm: altitudes[index % altitudes.count],
                         inclinationDeg: inclinations[(index / 6) % inclinations.count],
                         eccentricity: 0.0004,
                         tag: .starlink,
                         prefix: "SYNTH-LEO")
        case 12..<16:
            // Navigation constellation.
            return Shell(altitudeKm: 20_180,
                         inclinationDeg: 55,
                         eccentricity: 0.002,
                         tag: .navigation,
                         prefix: "SYNTH-NAV")
        case 16..<18:
            // Geostationary.
            return Shell(altitudeKm: 35_786,
                         inclinationDeg: 0.05,
                         eccentricity: 0.0002,
                         tag: .weather,
                         prefix: "SYNTH-GEO")
        default:
            // Sun-synchronous science.
            return Shell(altitudeKm: 700,
                         inclinationDeg: 98.2,
                         eccentricity: 0.001,
                         tag: .science,
                         prefix: "SYNTH-SCI")
        }
    }

    private static func record(id: Int, index: Int, shell: Shell) -> SatelliteRecord? {
        let raan = Double(index % 360)
        let meanAnomaly = Double((index * 7) % 360)
        let argPerigee = Double((index * 11) % 360)
        let meanMotion = revolutionsPerDay(altitudeKm: shell.altitudeKm)

        let name = "\(shell.prefix)-\(id)"
        let line1 = line1(id: id)
        let line2 = line2(id: id,
                          inclination: shell.inclinationDeg,
                          raan: raan,
                          eccentricity: shell.eccentricity,
                          argPerigee: argPerigee,
                          meanAnomaly: meanAnomaly,
                          meanMotion: meanMotion)

        guard let record = try? TLEParser.makeRecord(name: name,
                                                     line1: line1,
                                                     line2: line2,
                                                     groups: [shell.tag]) else { return nil }
        return record
    }

    /// WGS-72 gravitational parameter, matching `EarthConstants` (which keeps
    /// its own copy private).
    private static let gravitationalParameter = 398_600.8

    /// Circular-orbit mean motion in revolutions per day.
    private static func revolutionsPerDay(altitudeKm: Double) -> Double {
        let a = EarthConstants.Rₑ + altitudeKm
        let period = 2 * Double.pi * (a * a * a / gravitationalParameter).squareRoot()
        return 86_400 / period
    }

    // MARK: - TLE construction

    private static let baseLine1 = "1 25544U 98067A   26315.33607970  .00009043  00000+0  17017-3 0  9996"
    private static let baseLine2 = "2 25544  51.6323 291.9174 0007326  13.1877 346.9302 15.49313022594566"

    private static func line1(id: Int) -> String {
        tleLine(String(baseLine1.prefix(68)), [(2, String(format: "%05d", id))])
    }

    private static func line2(id: Int,
                              inclination: Double,
                              raan: Double,
                              eccentricity: Double,
                              argPerigee: Double,
                              meanAnomaly: Double,
                              meanMotion: Double) -> String {
        let eccentricDigits = String(format: "%07.0f",
                                     (eccentricity * 10_000_000).rounded())
        return tleLine(String(baseLine2.prefix(68)), [
            (2, String(format: "%05d", id)),
            (8, String(format: "%8.4f", inclination)),
            (17, String(format: "%8.4f", raan)),
            (26, String(eccentricDigits.prefix(7))),
            (34, String(format: "%8.4f", argPerigee)),
            (43, String(format: "%8.4f", meanAnomaly)),
            (52, String(format: "%11.8f", meanMotion).prefix(11).description),
        ])
    }

    /// Replace fixed-width fields in a 68-column body and append a valid checksum.
    private static func tleLine(_ body: String, _ replacements: [(column: Int, text: String)]) -> String {
        var characters = Array(body.prefix(68))
        for (column, text) in replacements {
            for (offset, character) in text.enumerated() where column + offset < characters.count {
                characters[column + offset] = character
            }
        }
        let line = String(characters)
        return line + String(checksum(line))
    }

    private static func checksum(_ line: String) -> Character {
        var sum = 0
        for character in line.prefix(68) {
            if character.isASCII, character.isNumber, let digit = character.wholeNumberValue {
                sum += digit
            } else if character == "-" {
                sum += 1
            }
        }
        return Character(String(sum % 10))
    }
}

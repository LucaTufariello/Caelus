//
//  TLEFixtures.swift
//  CaelusTests
//
//  Real element sets plus a generator that can mint a valid TLE for any NORAD
//  number, so the parser and the propagator can be exercised at full catalog
//  scale without touching the network.
//

import Foundation

enum TLEFixtures {

    /// A real ISS element set (epoch 2026 day 315), as served by CelesTrak.
    static let issName = "ISS (ZARYA)"
    static let issLine1 = "1 25544U 98067A   26315.33607970  .00009043  00000+0  17017-3 0  9996"
    static let issLine2 = "2 25544  51.6323 291.9174 0007326  13.1877 346.9302 15.49313022594566"

    /// A second real object, used for mismatch and dedup tests.
    static let poiskLine1 = "1 36086U 09060A   26315.33607970  .00009043  00000+0  17017-3 0  9994"
    static let poiskLine2 = "2 36086  51.6323 291.9174 0007326  13.1877 346.9302 15.49313022586762"

    static var issDocument: String {
        "\(issName)\n\(issLine1)\n\(issLine2)\n"
    }

    // MARK: - Checksums

    /// The standard TLE modulo-10 checksum over the first 68 columns.
    static func checksum(_ line: String) -> Character {
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

    /// Replace fixed-width fields in a 68-column body and append a valid checksum.
    static func tleLine(_ body: String, _ replacements: [(column: Int, text: String)]) -> String {
        var characters = Array(body.prefix(68))
        for (column, text) in replacements {
            for (offset, character) in text.enumerated() where column + offset < characters.count {
                characters[column + offset] = character
            }
        }
        let line = String(characters)
        return line + String(checksum(line))
    }

    /// Line 1 for an arbitrary NORAD number, reusing the ISS epoch and drag terms.
    static func line1(id: Int) -> String {
        let body = String(issLine1.prefix(68))
        return tleLine(body, [(2, String(format: "%05d", id))])
    }

    /// Line 2 for an arbitrary NORAD number, with the node spread round the orbit
    /// so a generated catalog is not a stack of coincident points.
    static func line2(id: Int, raan: Double) -> String {
        let body = String(issLine2.prefix(68))
        return tleLine(body, [
            (2, String(format: "%05d", id)),
            (17, String(format: "%8.4f", raan)),
        ])
    }

    static func document(id: Int, name: String, raan: Double) -> String {
        "\(name)\n\(line1(id: id))\n\(line2(id: id, raan: raan))\n"
    }

    /// A catalog of `count` valid, distinct, propagation-ready element sets.
    static func syntheticDocument(count: Int) -> String {
        var text = ""
        text.reserveCapacity(count * 150)
        for index in 0..<count {
            let id = 10_000 + index
            let raan = Double(index % 360)
            text += "SYNTH-\(id)\n"
            text += line1(id: id) + "\n"
            text += line2(id: id, raan: raan) + "\n"
        }
        return text
    }
}

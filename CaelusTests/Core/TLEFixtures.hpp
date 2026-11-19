// TLEFixtures.hpp — real element sets plus a generator that can mint a valid
// TLE for any NORAD number, so the parser and the propagator can be exercised
// at full catalog scale without touching the network.
//
// Ported from CaelusTests/TLEFixtures.swift.

#pragma once

#include <cstdio>
#include <string>
#include <utility>
#include <vector>

namespace fixtures {

// A real ISS element set (epoch 2026 day 315), as served by CelesTrak.
inline const std::string issName = "ISS (ZARYA)";
inline const std::string issLine1 =
    "1 25544U 98067A   26315.33607970  .00009043  00000+0  17017-3 0  9996";
inline const std::string issLine2 =
    "2 25544  51.6323 291.9174 0007326  13.1877 346.9302 15.49313022594566";

// A second real object, used for mismatch and dedup tests.
inline const std::string poiskLine1 =
    "1 36086U 09060A   26315.33607970  .00009043  00000+0  17017-3 0  9994";
inline const std::string poiskLine2 =
    "2 36086  51.6323 291.9174 0007326  13.1877 346.9302 15.49313022586762";

inline std::string issDocument() { return issName + "\n" + issLine1 + "\n" + issLine2 + "\n"; }

// MARK: - Checksums

// The standard TLE modulo-10 checksum over the first 68 columns.
inline char checksum(const std::string& line) {
    int sum = 0;
    const size_t limit = line.size() < 68 ? line.size() : 68;
    for (size_t index = 0; index < limit; ++index) {
        const char character = line[index];
        if (character >= '0' && character <= '9') {
            sum += character - '0';
        } else if (character == '-') {
            sum += 1;
        }
    }
    return static_cast<char>('0' + sum % 10);
}

// Replace fixed-width fields in a 68-column body and append a valid checksum.
inline std::string tleLine(const std::string& body,
                           const std::vector<std::pair<int, std::string>>& replacements) {
    std::string characters = body.size() > 68 ? body.substr(0, 68) : body;
    characters.resize(68, ' ');
    for (const auto& [column, text] : replacements) {
        for (size_t offset = 0; offset < text.size(); ++offset) {
            const size_t target = static_cast<size_t>(column) + offset;
            if (target < characters.size()) characters[target] = text[offset];
        }
    }
    return characters + checksum(characters);
}

// Line 1 for an arbitrary NORAD number, reusing the ISS epoch and drag terms.
inline std::string line1(int id) {
    char field[8];
    std::snprintf(field, sizeof(field), "%05d", id);
    return tleLine(issLine1.substr(0, 68), {{2, field}});
}

// Line 2 for an arbitrary NORAD number, with the node spread round the orbit
// so a generated catalog is not a stack of coincident points.
inline std::string line2(int id, double raan) {
    char idField[8];
    char raanField[16];
    std::snprintf(idField, sizeof(idField), "%05d", id);
    std::snprintf(raanField, sizeof(raanField), "%8.4f", raan);
    return tleLine(issLine2.substr(0, 68), {{2, idField}, {17, raanField}});
}

inline std::string document(int id, const std::string& name, double raan) {
    return name + "\n" + line1(id) + "\n" + line2(id, raan) + "\n";
}

// A catalog of `count` valid, distinct, propagation-ready element sets.
inline std::string syntheticDocument(int count) {
    std::string text;
    text.reserve(static_cast<size_t>(count) * 150);
    for (int index = 0; index < count; ++index) {
        const int id = 10000 + index;
        const double raan = static_cast<double>(index % 360);
        text += "SYNTH-" + std::to_string(id) + "\n";
        text += line1(id) + "\n";
        text += line2(id, raan) + "\n";
    }
    return text;
}

}  // namespace fixtures

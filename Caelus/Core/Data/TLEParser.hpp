// TLEParser.hpp — raw CelesTrak / SatNOGS text to SatelliteRecords.
//
// Translated from the Swift app's Data/TLEParser.swift. The Swift app validated
// every record structurally before handing it to SatelliteKit (whose initialiser
// force-unwrapped its numeric fields); the same checks and the same failure
// messages are preserved here so diagnostics read identically.

#pragma once

#include <cstdint>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

#include "Models.hpp"

namespace caelus {

class TLEParser {
public:
    struct Failure {
        std::string name;
        std::string reason;

        bool operator==(const Failure& other) const {
            return name == other.name && reason == other.reason;
        }
    };

    struct Result {
        std::vector<SatelliteRecord> records;
        std::vector<Failure> failures;
    };

    struct ParseError : std::runtime_error {
        using std::runtime_error::runtime_error;
    };

    // Parse a three-line-element document: three lines per object.
    static Result parse(const std::string& text, const std::set<SatelliteGroup>& groups);

    // Parse one validated object; throws ParseError.
    static SatelliteRecord makeRecord(const std::string& name, const std::string& line1,
                                      const std::string& line2,
                                      const std::set<SatelliteGroup>& groups);

    // CelesTrak sometimes prefixes the name with "0 " (three-line-element form).
    static std::string normaliseName(const std::string& raw);

    // Decode columns 2…6, which may use the Alpha-5 convention.
    static std::optional<int> noradID(const std::vector<uint8_t>& bytes);

    // Standard TLE modulo-10 checksum over columns 0…67.
    static bool checksumOK(const std::vector<uint8_t>& bytes);

    // Byte-level helpers, also useful to the fixture generator.
    static std::optional<int> intField(const std::vector<uint8_t>& bytes, size_t start,
                                       size_t end);
    static std::optional<double> doubleField(const std::vector<uint8_t>& bytes, size_t start,
                                             size_t end);

    static std::optional<double> parseDouble(const std::string& text);
};

// Line splitting on '\n', with '\r' tolerated for CRLF documents.
std::vector<std::string> splitLines(const std::string& text);

// Trim spaces and tabs (Swift's `trimmingCharacters(in: .whitespaces)`).
std::string trimWhitespace(const std::string& text);

}  // namespace caelus

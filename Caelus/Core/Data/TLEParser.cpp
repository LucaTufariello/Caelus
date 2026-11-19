#include "TLEParser.hpp"

#include <cctype>
#include <cmath>
#include <cstdlib>
#include <algorithm>
#include <sstream>

namespace caelus {
namespace {

std::vector<uint8_t> bytesOf(const std::string& text) {
    return std::vector<uint8_t>(text.begin(), text.end());
}

std::string slice(const std::vector<uint8_t>& bytes, size_t start, size_t end) {
    if (bytes.size() < end) return {};
    return std::string(bytes.begin() + static_cast<long>(start),
                       bytes.begin() + static_cast<long>(end));
}

bool allDigits(const std::string& text) {
    if (text.empty()) return false;
    for (char c : text) {
        if (!std::isdigit(static_cast<unsigned char>(c))) return false;
    }
    return true;
}

// Swift's Int(String) accepts an optional sign followed by digits, and nothing else.
std::optional<int> parseInteger(const std::string& text) {
    size_t index = 0;
    bool negative = false;
    if (index < text.size() && (text[index] == '+' || text[index] == '-')) {
        negative = text[index] == '-';
        ++index;
    }
    if (index == text.size()) return std::nullopt;
    if (!allDigits(text.substr(index))) return std::nullopt;

    const long value = std::strtol(text.c_str(), nullptr, 10);
    const long signedValue = negative ? -value : value;
    if (signedValue != static_cast<int>(signedValue)) return std::nullopt;
    return static_cast<int>(signedValue);
}

// First `count` UTF-8 code points of a string.
std::string prefixCharacters(const std::string& text, size_t count) {
    size_t codePoints = 0;
    size_t index = 0;
    while (index < text.size() && codePoints < count) {
        const unsigned char c = static_cast<unsigned char>(text[index]);
        size_t width = 1;
        if ((c & 0xE0) == 0xC0) {
            width = 2;
        } else if ((c & 0xF0) == 0xE0) {
            width = 3;
        } else if ((c & 0xF8) == 0xF0) {
            width = 4;
        }
        index += std::min(width, text.size() - index);
        ++codePoints;
    }
    return text.substr(0, index);
}

}  // namespace

std::vector<std::string> splitLines(const std::string& text) {
    std::vector<std::string> lines;
    std::string current;
    for (char c : text) {
        if (c == '\n' || c == '\r') {
            if (!current.empty()) lines.push_back(current);
            current.clear();
        } else {
            current.push_back(c);
        }
    }
    if (!current.empty()) lines.push_back(current);
    return lines;
}

std::string trimWhitespace(const std::string& text) {
    size_t begin = 0;
    size_t end = text.size();
    while (begin < end && (text[begin] == ' ' || text[begin] == '\t')) ++begin;
    while (end > begin && (text[end - 1] == ' ' || text[end - 1] == '\t')) --end;
    return text.substr(begin, end - begin);
}

std::optional<double> TLEParser::parseDouble(const std::string& text) {
    const std::string trimmed = trimWhitespace(text);
    if (trimmed.empty()) return std::nullopt;
    char* end = nullptr;
    const double value = std::strtod(trimmed.c_str(), &end);
    if (end == trimmed.c_str() || *end != '\0') return std::nullopt;
    return value;
}

std::optional<int> TLEParser::intField(const std::vector<uint8_t>& bytes, size_t start,
                                       size_t end) {
    if (bytes.size() < end) return std::nullopt;
    return parseInteger(trimWhitespace(slice(bytes, start, end)));
}

std::optional<double> TLEParser::doubleField(const std::vector<uint8_t>& bytes, size_t start,
                                             size_t end) {
    if (bytes.size() < end) return std::nullopt;
    return parseDouble(slice(bytes, start, end));
}

std::optional<int> TLEParser::noradID(const std::vector<uint8_t>& bytes) {
    if (bytes.size() < 7) return std::nullopt;
    const uint8_t first = bytes[2];

    int prefix = 0;
    if (first >= '0' && first <= '9') {
        prefix = first - '0';
    } else if (first >= 'A' && first <= 'H') {
        prefix = first - 'A' + 10;
    } else if (first >= 'J' && first <= 'N') {
        prefix = first - 'J' + 18;
    } else if (first >= 'P' && first <= 'Z') {
        prefix = first - 'P' + 23;
    } else {
        return std::nullopt;
    }

    const std::string rest = slice(bytes, 3, 7);
    if (!allDigits(rest)) return std::nullopt;
    return prefix * 10000 + static_cast<int>(std::strtol(rest.c_str(), nullptr, 10));
}

bool TLEParser::checksumOK(const std::vector<uint8_t>& bytes) {
    if (bytes.size() < 69) return false;
    int sum = 0;
    for (size_t i = 0; i < 68; ++i) {
        const uint8_t b = bytes[i];
        if (b >= '0' && b <= '9') {
            sum += b - '0';
        } else if (b == '-') {
            sum += 1;
        }
    }
    const uint8_t check = bytes[68];
    if (check < '0' || check > '9') return false;
    return sum % 10 == (check - '0');
}

std::string TLEParser::normaliseName(const std::string& raw) {
    std::string name = raw;
    if (name.rfind("0 ", 0) == 0) name.erase(0, 2);
    name = trimWhitespace(name);
    if (name.size() > 24) name = prefixCharacters(name, 24);
    return name;
}

SatelliteRecord TLEParser::makeRecord(const std::string& name, const std::string& line1,
                                      const std::string& line2,
                                      const std::set<SatelliteGroup>& groups) {
    const std::vector<uint8_t> b1 = bytesOf(line1);
    const std::vector<uint8_t> b2 = bytesOf(line2);

    if (b1.size() < 69) throw ParseError("line 1 is " + std::to_string(b1.size()) + " bytes");
    if (b2.size() < 69) throw ParseError("line 2 is " + std::to_string(b2.size()) + " bytes");
    if (b1[0] != '1') throw ParseError("line 1 does not start with '1'");
    if (b2[0] != '2') throw ParseError("line 2 does not start with '2'");

    const std::optional<int> id1 = noradID(b1);
    const std::optional<int> id2 = noradID(b2);
    if (!id1 || !id2) throw ParseError("unreadable NORAD id");
    if (*id1 != *id2) {
        throw ParseError("NORAD id mismatch (" + std::to_string(*id1) + " / " +
                         std::to_string(*id2) + ")");
    }

    if (!checksumOK(b1)) throw ParseError("line 1 checksum");
    if (!checksumOK(b2)) throw ParseError("line 2 checksum");

    // Fields SatelliteKit force-unwraps: prove they parse before handing over.
    const std::optional<int> epochYear = intField(b1, 18, 20);
    const std::optional<double> epochDay = doubleField(b1, 20, 32);
    const std::optional<int> elementNumber = intField(b1, 64, 68);
    if (!epochYear || !epochDay || !elementNumber) {
        throw ParseError("line 1 epoch/element number");
    }
    if (!(*epochDay >= 0.0 && *epochDay < 400.0)) {
        throw ParseError("epoch day " + std::to_string(*epochDay) + " out of range");
    }

    const std::optional<double> inclination = doubleField(b2, 8, 16);
    const std::optional<double> raan = doubleField(b2, 17, 25);
    const std::optional<double> eccentricity = parseDouble("0." + slice(b2, 26, 33));
    const std::optional<double> argPerigee = doubleField(b2, 34, 42);
    const std::optional<double> meanAnomaly = doubleField(b2, 43, 51);
    const std::optional<double> meanMotion = doubleField(b2, 52, 63);
    const std::optional<int> revNumber = intField(b2, 63, 68);
    if (!inclination || !raan || !eccentricity || !argPerigee || !meanAnomaly ||
        !meanMotion || !revNumber) {
        throw ParseError("line 2 element fields");
    }

    if (!(*inclination >= 0.0 && *inclination <= 180.0)) {
        throw ParseError("inclination " + std::to_string(*inclination));
    }
    if (!(*eccentricity >= 0.0 && *eccentricity < 1.0)) {
        throw ParseError("eccentricity " + std::to_string(*eccentricity));
    }
    if (!(*meanMotion > 0.0)) {
        throw ParseError("mean motion " + std::to_string(*meanMotion));
    }
    if (!(*raan >= 0.0 && *raan < 720.0) || !(*argPerigee >= 0.0 && *argPerigee < 720.0) ||
        !(*meanAnomaly >= 0.0 && *meanAnomaly < 720.0)) {
        throw ParseError("angle out of range");
    }
    (void)epochYear;
    (void)elementNumber;
    (void)revNumber;

    sky::Elements elements;
    try {
        elements = sky::Elements::parse(name, line1, line2);
    } catch (const std::exception& error) {
        throw ParseError(error.what());
    }

    // Cross-check the fields we validated so a silent mis-parse cannot slip through.
    if (static_cast<int>(elements.noradIndex) != *id1) {
        throw ParseError("parsed NORAD id " + std::to_string(elements.noradIndex) + " ≠ " +
                         std::to_string(*id1));
    }
    if (!(elements.n0 > 0.0) || !(elements.a0 > 0.0)) {
        throw ParseError("degenerate orbit");
    }

    const std::string displayName = name.empty() ? std::to_string(*id1) : name;

    SatelliteRecord record;
    record.id = *id1;
    record.name = displayName;
    record.elements = elements;
    record.groups = groups;
    record.epoch = sky::dateFromDays1950(elements.t0);
    return record;
}

TLEParser::Result TLEParser::parse(const std::string& text,
                                   const std::set<SatelliteGroup>& groups) {
    Result result;

    std::optional<std::string> pendingName;
    std::optional<std::string> pendingLine1;

    for (const std::string& rawLine : splitLines(text)) {
        const std::string line = trimWhitespace(rawLine);

        if (line.empty()) continue;

        if (line.rfind("1 ", 0) == 0) {
            if (pendingLine1) {
                // Two line-1s in a row: the first had no line 2.
                result.failures.push_back({pendingName.value_or("?"), "line 2 missing"});
            }
            pendingLine1 = line;
            continue;
        }

        if (line.rfind("2 ", 0) == 0) {
            if (!pendingLine1) {
                result.failures.push_back(
                    {pendingName.value_or("?"), "line 2 without line 1"});
                continue;
            }
            const std::string name = pendingName.value_or("");
            try {
                result.records.push_back(makeRecord(name, *pendingLine1, line, groups));
            } catch (const std::exception& error) {
                result.failures.push_back(
                    {name.empty() ? "?" : name, error.what()});
            }
            pendingName.reset();
            pendingLine1.reset();
            continue;
        }

        // Anything else is a name line. Keep the most recent one.
        pendingName = normaliseName(line);
    }

    if (pendingLine1) {
        result.failures.push_back({pendingName.value_or("?"), "truncated record"});
    }

    return result;
}

}  // namespace caelus

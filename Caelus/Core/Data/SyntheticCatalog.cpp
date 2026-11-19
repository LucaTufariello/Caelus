#include "SyntheticCatalog.hpp"

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace caelus {
namespace {

std::string format(const char* pattern, ...) {
    char buffer[128];
    va_list args;
    va_start(args, pattern);
    std::vsnprintf(buffer, sizeof(buffer), pattern, args);
    va_end(args);
    return buffer;
}

int parseLeadingInt(const char* raw) {
    if (raw == nullptr) return 0;
    char* end = nullptr;
    const long value = std::strtol(raw, &end, 10);
    if (end == raw) return 0;
    return static_cast<int>(value);
}

}  // namespace

const std::string& SyntheticCatalog::baseLine1() {
    static const std::string line =
        "1 25544U 98067A   26315.33607970  .00009043  00000+0  17017-3 0  9996";
    return line;
}

const std::string& SyntheticCatalog::baseLine2() {
    static const std::string line =
        "2 25544  51.6323 291.9174 0007326  13.1877 346.9302 15.49313022594566";
    return line;
}

int SyntheticCatalog::requestedCount() {
    const int count = parseLeadingInt(std::getenv("CAELUS_SYNTHETIC_CATALOG"));
    if (count <= 0) return 0;
    return count < 60000 ? count : 60000;
}

char SyntheticCatalog::checksum(const std::string& line) {
    int sum = 0;
    const size_t limit = std::min<size_t>(68, line.size());
    for (size_t index = 0; index < limit; ++index) {
        const char c = line[index];
        if (c >= '0' && c <= '9') {
            sum += c - '0';
        } else if (c == '-') {
            sum += 1;
        }
    }
    return static_cast<char>('0' + (sum % 10));
}

std::string SyntheticCatalog::tleLine(
    const std::string& body,
    const std::vector<std::pair<size_t, std::string>>& replacements) {
    std::string line = body.substr(0, std::min<size_t>(68, body.size()));
    for (const auto& [column, text] : replacements) {
        for (size_t offset = 0; offset < text.size() && column + offset < line.size(); ++offset) {
            line[column + offset] = text[offset];
        }
    }
    return line + checksum(line);
}

std::string SyntheticCatalog::makeLine1(int id) {
    return tleLine(baseLine1(), {{2, format("%05d", id)}});
}

std::string SyntheticCatalog::makeLine2(int id, double inclination, double raan,
                                        double eccentricity, double argPerigee,
                                        double meanAnomaly, double meanMotion) {
    const std::string eccentricDigits =
        format("%07.0f", std::round(eccentricity * 10000000.0));
    const std::string motion =
        format("%11.8f", meanMotion).substr(0, 11);

    return tleLine(baseLine2(), {
                                     {2, format("%05d", id)},
                                     {8, format("%8.4f", inclination)},
                                     {17, format("%8.4f", raan)},
                                     {26, eccentricDigits.substr(0, 7)},
                                     {34, format("%8.4f", argPerigee)},
                                     {43, format("%8.4f", meanAnomaly)},
                                     {52, motion},
                                 });
}

double SyntheticCatalog::revolutionsPerDay(double altitudeKm) {
    // WGS-72 gravitational parameter, matching EarthConstants.
    constexpr double gravitationalParameter = 398600.8;
    const double a = sky::EarthConstants::R_e + altitudeKm;
    const double period =
        2.0 * sky::kPi * std::sqrt(a * a * a / gravitationalParameter);
    return 86400.0 / period;
}

SyntheticCatalog::Shell SyntheticCatalog::shellFor(int index) {
    const int slot = index % 20;

    if (slot < 12) {
        // Low Earth orbit, the bulk of the catalog.
        static const double altitudes[] = {420, 520, 550, 570, 600, 780};
        static const double inclinations[] = {53, 70, 97.6, 43, 28.5, 82};
        return Shell{altitudes[index % 6],
                     inclinations[(index / 6) % 6],
                     0.0004,
                     SatelliteGroup::starlink,
                     "SYNTH-LEO"};
    }
    if (slot < 16) {
        // Navigation constellation.
        return Shell{20180, 55, 0.002, SatelliteGroup::navigation, "SYNTH-NAV"};
    }
    if (slot < 18) {
        // Geostationary.
        return Shell{35786, 0.05, 0.0002, SatelliteGroup::weather, "SYNTH-GEO"};
    }
    // Sun-synchronous science.
    return Shell{700, 98.2, 0.001, SatelliteGroup::science, "SYNTH-SCI"};
}

std::optional<SatelliteRecord> SyntheticCatalog::recordFor(int id, int index,
                                                           const Shell& shell) {
    const double raan = static_cast<double>(index % 360);
    const double meanAnomaly = static_cast<double>((index * 7) % 360);
    const double argPerigee = static_cast<double>((index * 11) % 360);
    const double meanMotion = revolutionsPerDay(shell.altitudeKm);

    const std::string name = shell.prefix + "-" + std::to_string(id);
    const std::string line1 = makeLine1(id);
    const std::string line2 = makeLine2(id, shell.inclinationDeg, raan, shell.eccentricity,
                                        argPerigee, meanAnomaly, meanMotion);

    try {
        return TLEParser::makeRecord(name, line1, line2, {shell.tag});
    } catch (...) {
        return std::nullopt;
    }
}

SyntheticCatalog::Made SyntheticCatalog::make(int count) {
    std::vector<SatelliteRecord> records;
    records.reserve(static_cast<size_t>(count));

    for (int index = 0; index < count; ++index) {
        const int id = 90000 + index;
        const Shell shell = shellFor(index);
        if (auto record = recordFor(id, index, shell)) {
            records.push_back(std::move(*record));
        }
    }

    LoadDiagnostics diagnostics;
    diagnostics.unpropagatable = count - static_cast<int>(records.size());

    Made made;
    made.catalog = SatelliteCatalog(std::move(records));
    made.diagnostics = diagnostics;
    return made;
}

}  // namespace caelus

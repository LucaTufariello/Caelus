// SyntheticCatalog.hpp — a QA-only catalog generator.
//
// Translated from the Swift app's Data/SyntheticCatalog.swift. The real catalog
// depends on CelesTrak's per-client two-hour window, which makes it impossible
// to exercise the 16 000-object render and propagation path on demand. Setting
// CAELUS_SYNTHETIC_CATALOG=<count> substitutes a generated catalog so the
// performance budgets can be measured reproducibly.
//
// These are NOT real satellites. Every surface that could be mistaken for live
// data reports SYNTHETIC while this mode is active.

#pragma once

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "../Sky/Astro.hpp"
#include "SatelliteCatalog.hpp"

namespace caelus {

class SyntheticCatalog {
public:
    // Number of objects requested, or 0 when the mode is off.
    static int requestedCount();
    static bool isEnabled() { return requestedCount() > 0; }

    struct Made {
        SatelliteCatalog catalog;
        LoadDiagnostics diagnostics;
    };

    // Build a catalog spread over plausible orbital shells.
    static Made make(int count);

    // MARK: - TLE construction (also used by the test fixtures)

    // Replace fixed-width fields in a 68-column body and append a valid checksum.
    static std::string tleLine(
        const std::string& body,
        const std::vector<std::pair<size_t, std::string>>& replacements);

    static char checksum(const std::string& line);

    static const std::string& baseLine1();
    static const std::string& baseLine2();

    static std::string makeLine1(int id);
    static std::string makeLine2(int id, double inclination, double raan, double eccentricity,
                                 double argPerigee, double meanAnomaly, double meanMotion);

    // Circular-orbit mean motion in revolutions per day for an altitude.
    static double revolutionsPerDay(double altitudeKm);

private:
    struct Shell {
        double altitudeKm;
        double inclinationDeg;
        double eccentricity;
        SatelliteGroup tag;
        std::string prefix;
    };

    static Shell shellFor(int index);
    static std::optional<SatelliteRecord> recordFor(int id, int index, const Shell& shell);
};

}  // namespace caelus

// Models.hpp — core value types shared by the data, propagation and UI layers.
//
// Translated from the Swift app's Data/Models.swift.

#pragma once

#include <optional>
#include <set>
#include <string>
#include <vector>

#include "../Sky/Astro.hpp"
#include "../Sky/Elements.hpp"
#include "../Sky/TimeUtil.hpp"

namespace caelus {

using sky::Date;

// MARK: - Groups

// The categories the app filters and colour-codes by. A satellite belongs to
// exactly one render group (see SatelliteRecord::renderGroup) but may carry
// several tags.
enum class SatelliteGroup {
    stations,
    starlink,
    navigation,
    weather,
    science,
    other,
};

const std::vector<SatelliteGroup>& allGroups();
std::string rawValue(SatelliteGroup group);
std::string title(SatelliteGroup group);

// The CelesTrak group whose membership tags a satellite with this category;
// nullopt means the category is derived rather than fetched.
std::optional<std::string> celestrakGroup(SatelliteGroup group);

// Groups that are small enough to always fetch for tagging purposes.
const std::vector<SatelliteGroup>& alwaysFetchedGroups();

// Order used when a satellite carries several tags; the first match decides
// which point cloud it is drawn in.
const std::vector<SatelliteGroup>& renderPriority();

// MARK: - Record

// One catalogued object: identity, orbital elements and the tags that came with them.
struct SatelliteRecord {
    int id = 0;  // NORAD catalog number
    std::string name;
    sky::Elements elements;
    std::set<SatelliteGroup> groups;
    Date epoch = 0.0;

    bool operator==(const SatelliteRecord& other) const { return id == other.id; }

    // International designator, e.g. "1998-067A".
    std::string cosparID() const { return elements.launchName; }

    // The group whose point cloud this satellite is drawn in.
    SatelliteGroup renderGroup() const;

    // MARK: Derived orbital geometry

    double inclinationDeg() const { return elements.i0 * 180.0 / sky::kPi; }
    double argumentOfPerigeeDeg() const { return elements.w0 * 180.0 / sky::kPi; }
    double raanDeg() const { return elements.raan0 * 180.0 / sky::kPi; }
    double eccentricity() const { return elements.e0; }
    double revolutionsPerDay() const { return elements.n0 * 1440.0 / (2.0 * sky::kPi); }

    // Orbital period in minutes; zero for degenerate elements.
    double periodMinutes() const {
        if (!(elements.n0 > 0.0)) return 0.0;
        return 2.0 * sky::kPi / elements.n0;
    }

    double semiMajorAxisKm() const { return elements.a0 * sky::EarthConstants::R_e; }
    double apogeeKm() const {
        return semiMajorAxisKm() * (1.0 + eccentricity()) - sky::EarthConstants::R_e;
    }
    double perigeeKm() const {
        return semiMajorAxisKm() * (1.0 - eccentricity()) - sky::EarthConstants::R_e;
    }

    // Age of the element set at a given instant, in seconds.
    double age(Date date) const { return date - epoch; }
};

// MARK: - Fetching

// The result of asking a source for one group.
struct FetchOutcome {
    enum class Kind { updated, unchanged };
    Kind kind = Kind::unchanged;
    std::string text;  // for `updated`, the fetched body; otherwise the group

    std::string value() const { return text; }
};

// Which source supplied the catalog currently on screen.
enum class DataProvenance { celestrak, satnogs, cache, synthetic, none };

std::string rawValue(DataProvenance provenance);

// Per-group cache bookkeeping, persisted beside the TLE text.
struct CacheMeta {
    std::string group;
    Date fetchedAt = 0.0;
    Date lastChecked = 0.0;
    int count = 0;
    std::optional<std::string> etag;

    // CelesTrak refreshes GP data once every two hours.
    static constexpr double refreshInterval = 2.0 * 60.0 * 60.0;
    // How long to wait before asking again after an "unchanged" answer.
    static constexpr double recheckInterval = 30.0 * 60.0;

    bool isDueForRefresh(Date now) const {
        return (now - lastChecked) > recheckInterval;
    }

    bool operator==(const CacheMeta& other) const {
        return group == other.group && fetchedAt == other.fetchedAt &&
               lastChecked == other.lastChecked && count == other.count && etag == other.etag;
    }
};

// MARK: - Diagnostics

// Non-fatal problems collected while loading, surfaced in the UI.
struct LoadDiagnostics {
    int parseFailures = 0;
    int duplicateRecords = 0;
    int unpropagatable = 0;
    std::vector<std::string> failedGroups;
    std::vector<std::string> messages;

    bool isEmpty() const {
        return parseFailures == 0 && duplicateRecords == 0 && unpropagatable == 0 &&
               failedGroups.empty() && messages.empty();
    }

    bool operator==(const LoadDiagnostics& other) const {
        return parseFailures == other.parseFailures &&
               duplicateRecords == other.duplicateRecords &&
               unpropagatable == other.unpropagatable &&
               failedGroups == other.failedGroups && messages == other.messages;
    }
};

// MARK: - Observer

// A ground station.
struct ObserverSite {
    std::string name;
    double latitude = 0.0;   // degrees
    double longitude = 0.0;  // degrees
    double altitudeKm = 0.0;

    sky::LatLonAlt latLonAlt() const { return {latitude, longitude, altitudeKm}; }

    // Rome — the default site.
    static ObserverSite rome() {
        return ObserverSite{"Rome", 41.9028, 12.4964, 0.0};
    }

    // A compact "41.9028° N, 12.4964° E" rendering.
    std::string formattedCoordinate() const;

    bool operator==(const ObserverSite& other) const {
        return name == other.name && latitude == other.latitude &&
               longitude == other.longitude && altitudeKm == other.altitudeKm;
    }
};

}  // namespace caelus

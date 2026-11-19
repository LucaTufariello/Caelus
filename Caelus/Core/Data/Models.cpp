#include "Models.hpp"

#include <cmath>
#include <cstdio>

namespace caelus {

const std::vector<SatelliteGroup>& allGroups() {
    static const std::vector<SatelliteGroup> groups = {
        SatelliteGroup::stations, SatelliteGroup::starlink, SatelliteGroup::navigation,
        SatelliteGroup::weather,  SatelliteGroup::science,  SatelliteGroup::other,
    };
    return groups;
}

std::string rawValue(SatelliteGroup group) {
    switch (group) {
        case SatelliteGroup::stations: return "stations";
        case SatelliteGroup::starlink: return "starlink";
        case SatelliteGroup::navigation: return "navigation";
        case SatelliteGroup::weather: return "weather";
        case SatelliteGroup::science: return "science";
        case SatelliteGroup::other: return "other";
    }
    return "other";
}

std::string title(SatelliteGroup group) {
    switch (group) {
        case SatelliteGroup::stations: return "Stations";
        case SatelliteGroup::starlink: return "Starlink";
        case SatelliteGroup::navigation: return "Navigation";
        case SatelliteGroup::weather: return "Weather";
        case SatelliteGroup::science: return "Science";
        case SatelliteGroup::other: return "Other";
    }
    return "Other";
}

std::optional<std::string> celestrakGroup(SatelliteGroup group) {
    switch (group) {
        case SatelliteGroup::stations: return std::string("stations");
        case SatelliteGroup::starlink: return std::string("starlink");
        case SatelliteGroup::navigation: return std::string("gps-ops");
        case SatelliteGroup::weather: return std::string("weather");
        case SatelliteGroup::science: return std::string("science");
        case SatelliteGroup::other: return std::nullopt;
    }
    return std::nullopt;
}

const std::vector<SatelliteGroup>& alwaysFetchedGroups() {
    static const std::vector<SatelliteGroup> groups = {
        SatelliteGroup::stations,
        SatelliteGroup::navigation,
        SatelliteGroup::weather,
        SatelliteGroup::science,
    };
    return groups;
}

const std::vector<SatelliteGroup>& renderPriority() { return allGroups(); }

SatelliteGroup SatelliteRecord::renderGroup() const {
    for (SatelliteGroup group : renderPriority()) {
        if (groups.count(group) != 0) return group;
    }
    return SatelliteGroup::other;
}

std::string rawValue(DataProvenance provenance) {
    switch (provenance) {
        case DataProvenance::celestrak: return "celestrak";
        case DataProvenance::satnogs: return "satnogs";
        case DataProvenance::cache: return "cache";
        case DataProvenance::synthetic: return "synthetic";
        case DataProvenance::none: return "none";
    }
    return "none";
}

std::string ObserverSite::formattedCoordinate() const {
    const char* ns = latitude >= 0 ? "N" : "S";
    const char* ew = longitude >= 0 ? "E" : "W";

    char buffer[96];
    std::snprintf(buffer, sizeof(buffer), "%.4f° %s, %.4f° %s", std::fabs(latitude), ns,
                  std::fabs(longitude), ew);
    return buffer;
}

}  // namespace caelus

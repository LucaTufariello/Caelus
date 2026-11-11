//
//  Models.swift
//  SatTracker
//
//  Core value types shared by the data, propagation and presentation layers.
//  Everything here is `Sendable` so it can cross actor boundaries freely.
//

import Foundation
import SatelliteKit

// MARK: - Groups

/// The categories the app filters and colour-codes by.
///
/// A satellite belongs to exactly one *render* group (see `renderGroup`) but may
/// carry several tags — the ISS, for instance, is both a station and part of the
/// active catalog.
enum SatelliteGroup: String, CaseIterable, Sendable, Codable, Identifiable {
    case stations
    case starlink
    case navigation
    case weather
    case science
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stations: "Stations"
        case .starlink: "Starlink"
        case .navigation: "Navigation"
        case .weather: "Weather"
        case .science: "Science"
        case .other: "Other"
        }
    }

    /// The CelesTrak group whose membership tags a satellite with this category.
    /// `nil` means the category is derived rather than fetched.
    var celestrakGroup: String? {
        switch self {
        case .stations: "stations"
        case .starlink: "starlink"
        case .navigation: "gps-ops"
        case .weather: "weather"
        case .science: "science"
        case .other: nil
        }
    }

    /// Groups that are small enough to always fetch for tagging purposes.
    static let alwaysFetched: [SatelliteGroup] = [.stations, .navigation, .weather, .science]

    /// Order used when a satellite carries several tags; the first match decides
    /// which point cloud it is drawn in.
    static let renderPriority: [SatelliteGroup] = [.stations, .starlink, .navigation, .weather, .science, .other]
}

// MARK: - Record

/// One catalogued object: identity, orbital elements and the tags that came with them.
struct SatelliteRecord: Identifiable, Sendable, Hashable {
    /// NORAD catalog number.
    let id: Int
    let name: String
    let elements: Elements
    let groups: Set<SatelliteGroup>
    let epoch: Date

    static func == (lhs: SatelliteRecord, rhs: SatelliteRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// International designator, e.g. `1998-067A`.
    var cosparID: String { elements.launchName }

    /// The group whose point cloud this satellite is drawn in.
    var renderGroup: SatelliteGroup {
        for group in SatelliteGroup.renderPriority where groups.contains(group) {
            return group
        }
        return .other
    }

    // MARK: Derived orbital geometry

    /// Inclination in degrees.
    var inclinationDeg: Double { elements.i₀ * 180 / .pi }

    /// Argument of perigee in degrees.
    var argumentOfPerigeeDeg: Double { elements.ω₀ * 180 / .pi }

    /// Right ascension of the ascending node in degrees.
    var raanDeg: Double { elements.Ω₀ * 180 / .pi }

    /// Eccentricity, dimensionless.
    var eccentricity: Double { elements.e₀ }

    /// Mean motion in revolutions per day.
    var revolutionsPerDay: Double { elements.n₀ * 1440 / (2 * .pi) }

    /// Orbital period in minutes. Falls back to zero for degenerate elements.
    var periodMinutes: Double {
        guard elements.n₀ > 0 else { return 0 }
        return 2 * .pi / elements.n₀
    }

    /// Semi-major axis in kilometres.
    var semiMajorAxisKm: Double { elements.a₀ * EarthConstants.Rₑ }

    /// Apogee altitude above the equatorial radius, kilometres.
    var apogeeKm: Double { semiMajorAxisKm * (1 + eccentricity) - EarthConstants.Rₑ }

    /// Perigee altitude above the equatorial radius, kilometres.
    var perigeeKm: Double { semiMajorAxisKm * (1 - eccentricity) - EarthConstants.Rₑ }

    /// Age of the element set at a given instant.
    func age(at date: Date) -> TimeInterval { date.timeIntervalSince(epoch) }
}

// MARK: - Fetching

/// The result of asking a source for one group.
enum FetchOutcome: Sendable {
    /// Fresh text was downloaded.
    case updated(String)
    /// The source says the data has not changed since the last download.
    /// The caller keeps its cache and only moves `lastChecked` forward.
    case unchanged(String)
}

/// Which source supplied the catalog currently on screen.
enum DataProvenance: String, Sendable, Codable {
    case celestrak
    case satnogs
    case cache
    case none
}

/// Per-group cache bookkeeping, persisted beside the TLE text.
struct CacheMeta: Codable, Sendable, Equatable {
    var group: String
    var fetchedAt: Date
    var lastChecked: Date
    var count: Int
    var etag: String?

    /// CelesTrak refreshes GP data once every two hours.
    static let refreshInterval: TimeInterval = 2 * 60 * 60
    /// How long to wait before asking again after an "unchanged" answer.
    static let recheckInterval: TimeInterval = 30 * 60

    var isDueForRefresh: Bool {
        lastChecked.timeIntervalSinceNow < -CacheMeta.recheckInterval
    }
}

// MARK: - Diagnostics

/// Non-fatal problems collected while loading, surfaced in the UI.
struct LoadDiagnostics: Sendable, Equatable {
    var parseFailures: Int = 0
    var duplicateRecords: Int = 0
    var unpropagatable: Int = 0
    var failedGroups: [String] = []
    var messages: [String] = []

    var isEmpty: Bool {
        parseFailures == 0 && duplicateRecords == 0 && unpropagatable == 0
            && failedGroups.isEmpty && messages.isEmpty
    }
}

// MARK: - Observer

/// A ground station.
struct ObserverSite: Sendable, Equatable, Codable {
    var name: String
    var latitude: Double
    var longitude: Double
    /// Height above the geoid, kilometres.
    var altitudeKm: Double

    init(name: String, latitude: Double, longitude: Double, altitudeKm: Double = 0) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeKm = altitudeKm
    }

    var latLonAlt: LatLonAlt { LatLonAlt(latitude, longitude, altitudeKm) }

    /// Rome — the default site.
    static let rome = ObserverSite(name: "Rome", latitude: 41.9028, longitude: 12.4964)

    /// A compact "41.9028° N, 12.4964° E" rendering.
    var formattedCoordinate: String {
        let ns = latitude >= 0 ? "N" : "S"
        let ew = longitude >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(latitude), ns, abs(longitude), ew)
    }
}

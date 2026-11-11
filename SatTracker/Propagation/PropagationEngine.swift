//
//  PropagationEngine.swift
//  SatTracker
//
//  SGP4/SDP4 propagation for the whole catalog.
//
//  `Satellite` objects are built once per catalog load — the propagator
//  initialiser is by far the most expensive part of the pipeline. Each tick then
//  splits the catalog into chunks and propagates them concurrently, producing an
//  immutable snapshot in catalog order. The renderer interpolates between the
//  two most recent snapshots, so a 1 Hz tick still looks like continuous motion.
//

import Foundation
import SatelliteKit
import simd
import os

// MARK: - Snapshot

/// One instant of the whole catalog, in catalog order.
struct SatelliteSnapshot: Sendable {
    let time: Date
    /// Scene positions (1 unit = one Earth radius). Meaningless where `valid` is false.
    let positions: [SIMD3<Float>]
    let valid: [Bool]
    /// Wall-clock cost of producing this snapshot.
    let duration: TimeInterval
    /// Catalog indices that failed to propagate.
    let failures: Int

    static let empty = SatelliteSnapshot(time: .distantPast, positions: [], valid: [],
                                         duration: 0, failures: 0)

    var count: Int { positions.count }
}

/// A single satellite's current state, computed on demand for the inspector.
struct SatelliteState: Sendable {
    let position: SIMD3<Float>
    let latitude: Double
    let longitude: Double
    let altitudeKm: Double
    let velocityKmS: Double
    let sunlit: Bool
    let rangeToObserverKm: Double?
    let elevationFromObserver: Double?
    let azimuthFromObserver: Double?
}

// MARK: - Snapshot buffer

/// Lock-protected hand-off between the propagation actor and the render thread.
///
/// The render callback runs on SceneKit's render thread, so it cannot await the
/// engine. Snapshots are pushed here and read synchronously.
final class SnapshotBuffer: @unchecked Sendable {

    private struct State {
        var previous: SatelliteSnapshot = .empty
        var current: SatelliteSnapshot = .empty
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    func push(_ snapshot: SatelliteSnapshot) {
        lock.withLock { state in
            // A snapshot for the same instant replaces rather than shifts, so a
            // paused clock does not produce a zero-length interpolation window.
            if state.current.time == snapshot.time {
                state.current = snapshot
            } else {
                state.previous = state.current
                state.current = snapshot
            }
        }
    }

    func pair() -> (previous: SatelliteSnapshot, current: SatelliteSnapshot) {
        lock.withLock { ($0.previous, $0.current) }
    }

    func clear() {
        lock.withLock { $0 = State() }
    }

    var currentTime: Date {
        lock.withLock { $0.current.time }
    }
}

// MARK: - Engine

actor PropagationEngine {

    private var records: [SatelliteRecord] = []
    private var satellites: [Satellite] = []
    private var unpropagatable: Set<Int> = []

    /// Number of chunks used per tick; a few per core keeps the tail short.
    private let chunkMultiplier = 3

    // MARK: Loading

    /// Build propagators for a catalog. Safe to call repeatedly.
    func load(_ records: [SatelliteRecord]) {
        self.records = records
        self.unpropagatable.removeAll()
        var built: [Satellite] = []
        built.reserveCapacity(records.count)
        for record in records {
            built.append(Satellite(elements: record.elements))
        }
        self.satellites = built
    }

    var loadedCount: Int { satellites.count }

    func satellite(at index: Int) -> Satellite? {
        guard satellites.indices.contains(index) else { return nil }
        return satellites[index]
    }

    func record(at index: Int) -> SatelliteRecord? {
        guard records.indices.contains(index) else { return nil }
        return records[index]
    }

    func unpropagatableIndices() -> Set<Int> { unpropagatable }

    // MARK: Ticking

    /// Propagate every satellite to `date`.
    func tick(at date: Date) async -> SatelliteSnapshot {
        let count = satellites.count
        guard count > 0 else { return .empty }

        let clock = ContinuousClock()
        let start = clock.now
        let julian = date.julianDate
        let sats = satellites

        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunks = max(1, min(cores * chunkMultiplier, count))
        let chunkSize = (count + chunks - 1) / chunks

        var positions = [SIMD3<Float>](repeating: .zero, count: count)
        var valid = [Bool](repeating: false, count: count)
        var failedIndices: [Int] = []

        await withTaskGroup(of: Chunk.self) { group in
            for chunk in 0..<chunks {
                let lower = chunk * chunkSize
                let upper = min(count, lower + chunkSize)
                guard lower < upper else { continue }
                group.addTask {
                    Self.propagate(sats, from: lower, to: upper, julian: julian)
                }
            }

            for await result in group {
                positions.replaceSubrange(result.lower..<(result.lower + result.positions.count),
                                         with: result.positions)
                valid.replaceSubrange(result.lower..<(result.lower + result.valid.count),
                                      with: result.valid)
                failedIndices.append(contentsOf: result.failures)
            }
        }

        if !failedIndices.isEmpty {
            unpropagatable.formUnion(failedIndices)
        }

        let elapsed = clock.now - start
        return SatelliteSnapshot(time: date,
                                 positions: positions,
                                 valid: valid,
                                 duration: elapsed.seconds,
                                 failures: failedIndices.count)
    }

    private struct Chunk: Sendable {
        let lower: Int
        let positions: [SIMD3<Float>]
        let valid: [Bool]
        let failures: [Int]
    }

    private nonisolated static func propagate(_ sats: [Satellite],
                                              from lower: Int,
                                              to upper: Int,
                                              julian: Double) -> Chunk {
        let n = upper - lower
        var positions = [SIMD3<Float>](repeating: .zero, count: n)
        var valid = [Bool](repeating: false, count: n)
        var failures: [Int] = []

        for offset in 0..<n {
            let index = lower + offset
            let satellite = sats[index]
            do {
                let lla = try satellite.geoPosition(julianDays: julian)
                positions[offset] = GeoMath.scenePosition(lla)
                valid[offset] = true
            } catch {
                failures.append(index)
            }
        }
        return Chunk(lower: lower, positions: positions, valid: valid, failures: failures)
    }

    // MARK: On-demand state

    /// Full state for one satellite — used by the inspector at tick rate.
    func state(at index: Int, date: Date, site: ObserverSite?) -> SatelliteState? {
        guard satellites.indices.contains(index) else { return nil }
        let satellite = satellites[index]
        let julian = date.julianDate

        guard let lla = try? satellite.geoPosition(julianDays: julian) else { return nil }
        let velocity = (try? satellite.velocity(julianDays: julian)).map { $0.magnitude() } ?? 0
        let eci = (try? satellite.position(julianDays: julian)) ?? Vector(0, 0, 0)
        let sunlit = SunCalculator.isSunlit(satelliteECI: eci, at: date)

        var range: Double?
        var elevation: Double?
        var azimuth: Double?
        if let site {
            if let top = try? satellite.topPosition(julianDays: julian, observer: site.latLonAlt) {
                range = top.dist
                elevation = top.elev
                azimuth = top.azim
            }
        }

        return SatelliteState(position: GeoMath.scenePosition(lla),
                              latitude: lla.lat,
                              longitude: lla.lon,
                              altitudeKm: lla.alt,
                              velocityKmS: velocity,
                              sunlit: sunlit,
                              rangeToObserverKm: range,
                              elevationFromObserver: elevation,
                              azimuthFromObserver: azimuth)
    }

    /// Predicted passes over a site.
    ///
    /// Runs on the engine's executor rather than the caller's, because a
    /// 24-hour scan at 30-second resolution is thousands of propagations.
    func passes(at index: Int,
                site: ObserverSite,
                from start: Date,
                hours: Double,
                minElevation: Double,
                limit: Int) -> [PassEvent] {
        guard satellites.indices.contains(index) else { return [] }
        return PassPredictor.passes(satellite: satellites[index],
                                    site: site,
                                    from: start,
                                    hours: hours,
                                    minElevation: minElevation,
                                    limit: limit)
    }

    /// Geodetic samples along the orbit, for the orbit path and ground track.
    ///
    /// - Parameters:
    ///   - index: Catalog index.
    ///   - date: Reference instant.
    ///   - halfSpanMinutes: How far either side of `date` to sample.
    ///   - stepSeconds: Sample spacing.
    func trackSamples(at index: Int,
                      date: Date,
                      halfSpanMinutes: Double,
                      stepSeconds: Double) -> [TrackSample] {
        guard satellites.indices.contains(index) else { return [] }
        let satellite = satellites[index]
        let julian = date.julianDate
        let stepMinutes = stepSeconds / 60

        var samples: [TrackSample] = []
        samples.reserveCapacity(Int(2 * halfSpanMinutes / stepMinutes) + 2)

        var offset = -halfSpanMinutes
        while offset <= halfSpanMinutes {
            let jd = julian + offset / 1440
            if let lla = try? satellite.geoPosition(julianDays: jd) {
                samples.append(TrackSample(offsetMinutes: offset,
                                           latitude: lla.lat,
                                           longitude: lla.lon,
                                           altitudeKm: lla.alt))
            }
            offset += stepMinutes
        }
        return samples
    }
}

/// One point along an orbit or ground track.
struct TrackSample: Sendable, Equatable {
    let offsetMinutes: Double
    let latitude: Double
    let longitude: Double
    let altitudeKm: Double
}

extension Duration {
    /// Seconds as a `Double`.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

// PropagationEngine.hpp — SGP4/SDP4 propagation for the whole catalog.
//
// Translated from the Swift app's Propagation/PropagationEngine.swift.
//
// `sky::Satellite` objects are built once per catalog load — the propagator
// initialiser is by far the most expensive part of the pipeline. Each tick then
// splits the catalog into chunks and propagates them concurrently, producing an
// immutable snapshot in catalog order. The renderer interpolates between the two
// most recent snapshots, so a 1 Hz tick still looks like continuous motion.

#pragma once

#include <mutex>
#include <optional>
#include <set>
#include <utility>
#include <vector>

#include "../Data/Models.hpp"
#include "../Geo/GeoMath.hpp"
#include "../Sky/Satellite.hpp"
#include "PassPredictor.hpp"

namespace caelus {

// MARK: - Snapshot

// One instant of the whole catalog, in catalog order.
struct SatelliteSnapshot {
    Date time = -1.0e12;
    std::vector<sky::Vec3> positions;  // scene units; meaningless where `valid` is false
    std::vector<bool> valid;
    double duration = 0.0;  // wall-clock cost of producing this snapshot
    int failures = 0;       // catalog indices that failed to propagate

    static SatelliteSnapshot empty() { return SatelliteSnapshot(); }
    size_t count() const { return positions.size(); }
};

// A single satellite's current state, computed on demand for the inspector.
struct SatelliteState {
    sky::Vec3 position;
    double latitude = 0.0;
    double longitude = 0.0;
    double altitudeKm = 0.0;
    double velocityKmS = 0.0;
    bool sunlit = false;
    std::optional<double> rangeToObserverKm;
    std::optional<double> elevationFromObserver;
    std::optional<double> azimuthFromObserver;
};

// One point along an orbit or ground track.
struct TrackSample {
    double offsetMinutes = 0.0;
    double latitude = 0.0;
    double longitude = 0.0;
    double altitudeKm = 0.0;

    bool operator==(const TrackSample& other) const {
        return offsetMinutes == other.offsetMinutes && latitude == other.latitude &&
               longitude == other.longitude && altitudeKm == other.altitudeKm;
    }
};

// MARK: - Snapshot buffer

// Lock-protected hand-off between the propagation thread and the render thread.
class SnapshotBuffer {
public:
    void push(const SatelliteSnapshot& snapshot);
    std::pair<SatelliteSnapshot, SatelliteSnapshot> pair() const;
    void clear();
    Date currentTime() const;

private:
    mutable std::mutex mutex_;
    SatelliteSnapshot previous_;
    SatelliteSnapshot current_;
};

// MARK: - Engine

class PropagationEngine {
public:
    PropagationEngine() = default;

    // MARK: Loading

    // Build propagators for a catalog. Safe to call repeatedly.
    void load(const std::vector<SatelliteRecord>& records);

    size_t loadedCount() const;
    std::optional<sky::Satellite> satellite(size_t index) const;
    std::optional<SatelliteRecord> record(size_t index) const;
    std::set<size_t> unpropagatableIndices() const;

    // MARK: Ticking

    // Propagate every satellite to `date`.
    SatelliteSnapshot tick(Date date);

    // MARK: On-demand state

    // Full state for one satellite — used by the inspector at tick rate.
    std::optional<SatelliteState> state(size_t index, Date date,
                                        const ObserverSite* site) const;

    // Predicted passes over a site.
    std::vector<PassEvent> passes(size_t index, const ObserverSite& site, Date start,
                                  double hours, double minElevation, int limit) const;

    // Geodetic samples along the orbit, for the orbit path and ground track.
    std::vector<TrackSample> trackSamples(size_t index, Date date, double halfSpanMinutes,
                                          double stepSeconds) const;

private:
    mutable std::mutex mutex_;
    std::vector<SatelliteRecord> records_;
    std::vector<sky::Satellite> satellites_;
    std::set<size_t> unpropagatable_;
};

}  // namespace caelus

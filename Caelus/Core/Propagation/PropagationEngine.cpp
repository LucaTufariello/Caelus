#include "PropagationEngine.hpp"

#include <algorithm>
#include <chrono>
#include <thread>

#include "SunCalculator.hpp"

namespace caelus {

using sky::LatLonAlt;
using sky::Vec3;

// MARK: - Snapshot buffer

void SnapshotBuffer::push(const SatelliteSnapshot& snapshot) {
    std::lock_guard<std::mutex> guard(mutex_);
    // A snapshot for the same instant replaces rather than shifts, so a paused
    // clock does not produce a zero-length interpolation window.
    if (current_.time == snapshot.time) {
        current_ = snapshot;
    } else {
        previous_ = current_;
        current_ = snapshot;
    }
}

std::pair<SatelliteSnapshot, SatelliteSnapshot> SnapshotBuffer::pair() const {
    std::lock_guard<std::mutex> guard(mutex_);
    return {previous_, current_};
}

void SnapshotBuffer::clear() {
    std::lock_guard<std::mutex> guard(mutex_);
    previous_ = SatelliteSnapshot();
    current_ = SatelliteSnapshot();
}

Date SnapshotBuffer::currentTime() const {
    std::lock_guard<std::mutex> guard(mutex_);
    return current_.time;
}

// MARK: - Engine

void PropagationEngine::load(const std::vector<SatelliteRecord>& records) {
    std::lock_guard<std::mutex> guard(mutex_);
    records_ = records;
    unpropagatable_.clear();

    std::vector<sky::Satellite> built;
    built.reserve(records.size());
    for (const SatelliteRecord& record : records) {
        built.emplace_back(record.elements);
    }
    satellites_ = std::move(built);
}

size_t PropagationEngine::loadedCount() const {
    std::lock_guard<std::mutex> guard(mutex_);
    return satellites_.size();
}

std::optional<sky::Satellite> PropagationEngine::satellite(size_t index) const {
    std::lock_guard<std::mutex> guard(mutex_);
    if (index >= satellites_.size()) return std::nullopt;
    return satellites_[index];
}

std::optional<SatelliteRecord> PropagationEngine::record(size_t index) const {
    std::lock_guard<std::mutex> guard(mutex_);
    if (index >= records_.size()) return std::nullopt;
    return records_[index];
}

std::set<size_t> PropagationEngine::unpropagatableIndices() const {
    std::lock_guard<std::mutex> guard(mutex_);
    return unpropagatable_;
}

SatelliteSnapshot PropagationEngine::tick(Date date) {
    std::lock_guard<std::mutex> guard(mutex_);

    const size_t count = satellites_.size();
    if (count == 0) return SatelliteSnapshot::empty();

    const auto start = std::chrono::steady_clock::now();
    const double julian = sky::julianFromDate(date);

    // A few chunks per core keeps the tail short.
    const unsigned hardware = std::thread::hardware_concurrency();
    const size_t cores = hardware == 0 ? 1 : hardware;
    const size_t chunks = std::max<size_t>(1, std::min<size_t>(cores * 3, count));
    const size_t chunkSize = (count + chunks - 1) / chunks;

    std::vector<Vec3> positions(count);
    std::vector<uint8_t> validBytes(count, 0);
    std::vector<std::vector<size_t>> chunkFailures(chunks);
    std::vector<std::thread> threads;
    threads.reserve(chunks);

    for (size_t chunk = 0; chunk < chunks; ++chunk) {
        const size_t lower = chunk * chunkSize;
        const size_t upper = std::min(count, lower + chunkSize);
        if (lower >= upper) continue;

        threads.emplace_back([this, lower, upper, julian, &positions, &validBytes,
                              &chunkFailures, chunk] {
            for (size_t index = lower; index < upper; ++index) {
                try {
                    const LatLonAlt lla = satellites_[index].geoPosition(julian);
                    positions[index] = GeoMath::scenePosition(lla);
                    validBytes[index] = 1;
                } catch (...) {
                    chunkFailures[chunk].push_back(index);
                }
            }
        });
    }

    for (std::thread& thread : threads) thread.join();

    SatelliteSnapshot snapshot;
    snapshot.time = date;
    snapshot.positions = std::move(positions);
    snapshot.valid.resize(count);
    int failed = 0;
    for (size_t index = 0; index < count; ++index) {
        snapshot.valid[index] = validBytes[index] != 0;
    }
    for (const std::vector<size_t>& failures : chunkFailures) {
        failed += static_cast<int>(failures.size());
        for (size_t index : failures) unpropagatable_.insert(index);
    }
    snapshot.failures = failed;

    const auto end = std::chrono::steady_clock::now();
    snapshot.duration = std::chrono::duration<double>(end - start).count();
    return snapshot;
}

std::optional<SatelliteState> PropagationEngine::state(size_t index, Date date,
                                                       const ObserverSite* site) const {
    std::lock_guard<std::mutex> guard(mutex_);
    if (index >= satellites_.size()) return std::nullopt;

    const sky::Satellite& satellite = satellites_[index];
    const double julian = sky::julianFromDate(date);

    LatLonAlt lla;
    try {
        lla = satellite.geoPosition(julian);
    } catch (...) {
        return std::nullopt;
    }

    double velocity = 0.0;
    try {
        velocity = satellite.velocity(julian).magnitude();
    } catch (...) {
    }

    Vec3 eci;
    try {
        eci = satellite.position(julian);
    } catch (...) {
        eci = Vec3(0, 0, 0);
    }
    const bool sunlit = SunCalculator::isSunlit(eci, date);

    SatelliteState state;
    state.position = GeoMath::scenePosition(lla);
    state.latitude = lla.lat;
    state.longitude = GeoMath::wrapLongitude(lla.lon);
    state.altitudeKm = lla.alt;
    state.velocityKmS = velocity;
    state.sunlit = sunlit;

    if (site != nullptr) {
        try {
            const sky::AziEleDst top = satellite.topPosition(julian, site->latLonAlt());
            state.rangeToObserverKm = top.dist;
            state.elevationFromObserver = top.elev;
            state.azimuthFromObserver = top.azim;
        } catch (...) {
        }
    }

    return state;
}

std::vector<PassEvent> PropagationEngine::passes(size_t index, const ObserverSite& site,
                                                 Date start, double hours,
                                                 double minElevation, int limit) const {
    std::lock_guard<std::mutex> guard(mutex_);
    if (index >= satellites_.size()) return {};
    return PassPredictor::passes(satellites_[index], site, start, hours, minElevation, limit);
}

std::vector<TrackSample> PropagationEngine::trackSamples(size_t index, Date date,
                                                         double halfSpanMinutes,
                                                         double stepSeconds) const {
    std::lock_guard<std::mutex> guard(mutex_);
    if (index >= satellites_.size()) return {};

    const sky::Satellite& satellite = satellites_[index];
    const double julian = sky::julianFromDate(date);
    const double stepMinutes = stepSeconds / 60.0;

    std::vector<TrackSample> samples;
    if (stepMinutes <= 0.0) return samples;
    samples.reserve(static_cast<size_t>(2.0 * halfSpanMinutes / stepMinutes) + 2);

    double offset = -halfSpanMinutes;
    while (offset <= halfSpanMinutes) {
        const double julianAtOffset = julian + offset / 1440.0;
        try {
            const LatLonAlt lla = satellite.geoPosition(julianAtOffset);
            samples.push_back(TrackSample{offset, lla.lat, GeoMath::wrapLongitude(lla.lon),
                                          lla.alt});
        } catch (...) {
            // A sample that fails to propagate is simply absent, as in Swift.
        }
        offset += stepMinutes;
    }
    return samples;
}

}  // namespace caelus

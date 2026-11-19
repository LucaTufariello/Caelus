// PassPredictor.hpp — visible passes for a ground site over the next N hours.
//
// Translated from the Swift app's Propagation/PassPredictor.swift. A coarse scan
// finds every threshold crossing, then bisection refines each rise and set to
// sub-second precision.

#pragma once

#include <string>
#include <vector>

#include "../Data/Models.hpp"
#include "../Sky/Satellite.hpp"

namespace caelus {

// A single pass over the observer's horizon.
struct PassEvent {
    Date rise = 0.0;
    Date peak = 0.0;
    Date set = 0.0;
    double maxElevation = 0.0;  // degrees
    double riseAzimuth = 0.0;   // degrees
    double peakAzimuth = 0.0;
    double setAzimuth = 0.0;
    double rangeAtPeakKm = 0.0;
    bool isVisible = false;  // satellite sunlit while the observer is dark

    Date id() const { return rise; }
    double duration() const { return set - rise; }

    // Compass point for the peak azimuth.
    std::string peakDirection() const;
    std::string riseDirection() const;
    std::string setDirection() const;

    bool operator==(const PassEvent& other) const {
        return rise == other.rise && peak == other.peak && set == other.set &&
               maxElevation == other.maxElevation && riseAzimuth == other.riseAzimuth &&
               peakAzimuth == other.peakAzimuth && setAzimuth == other.setAzimuth &&
               rangeAtPeakKm == other.rangeAtPeakKm && isVisible == other.isVisible;
    }
};

class Compass {
public:
    static const std::vector<std::string>& names();
    static std::string direction(double azimuth);
};

class PassPredictor {
public:
    // Default scan resolution. A 30 s grid cannot miss a pass that clears the
    // horizon for more than a minute, which covers every useful pass.
    static constexpr double scanStep = 30.0;

    // Predict passes for one satellite.
    static std::vector<PassEvent> passes(const sky::Satellite& satellite,
                                         const ObserverSite& site, Date start,
                                         double hours = 48.0,
                                         double minElevation = 10.0, int limit = 50);

    // Naked-eye visibility: the satellite is in sunlight while the observer is
    // past civil twilight.
    static bool isVisible(const sky::Satellite& satellite, Date date,
                          const ObserverSite& site);

    // Sample the elevation curve across a pass, for the sparkline in the UI.
    static std::vector<double> elevationProfile(const sky::Satellite& satellite,
                                                const ObserverSite& site,
                                                const PassEvent& pass,
                                                int samples = 48);
};

}  // namespace caelus

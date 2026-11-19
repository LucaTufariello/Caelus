#include "PassPredictor.hpp"

#include <algorithm>
#include <cmath>
#include <optional>

#include "SunCalculator.hpp"

namespace caelus {

const std::vector<std::string>& Compass::names() {
    static const std::vector<std::string> names = {
        "N",  "NNE", "NE",  "ENE", "E",  "ESE", "SE",  "SSE",
        "S",  "SSW", "SW",  "WSW", "W",  "WNW", "NW",  "NNW",
    };
    return names;
}

std::string Compass::direction(double azimuth) {
    double value = std::fmod(azimuth, 360.0);  // Swift's truncatingRemainder
    if (value < 0.0) value += 360.0;
    const int index = static_cast<int>(std::round(value / 22.5)) % 16;
    return names()[index];
}

std::string PassEvent::peakDirection() const { return Compass::direction(peakAzimuth); }
std::string PassEvent::riseDirection() const { return Compass::direction(riseAzimuth); }
std::string PassEvent::setDirection() const { return Compass::direction(setAzimuth); }

namespace {

std::optional<double> elevationAt(const sky::Satellite& satellite,
                                  const sky::LatLonAlt& observer, Date date) {
    try {
        return satellite.topPosition(sky::julianFromDate(date), observer).elev;
    } catch (...) {
        return std::nullopt;
    }
}

// Bisection between two samples that straddle the threshold.
Date refineCrossing(const sky::Satellite& satellite, const sky::LatLonAlt& observer,
                    Date lower, Date upper, double threshold, bool rising) {
    Date lo = lower;
    Date hi = upper;
    for (int step = 0; step < 24; ++step) {
        const Date mid = lo + (hi - lo) / 2.0;
        const std::optional<double> elevation =
            elevationAt(satellite, observer, mid);
        if (!elevation) break;
        const bool above = *elevation >= threshold;
        if (above == rising) {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    return lo + (hi - lo) / 2.0;
}

std::optional<PassEvent> makeEvent(const sky::Satellite& satellite, const ObserverSite& site,
                                   Date rise, Date peak, Date set, double maxElevation) {
    const sky::LatLonAlt observer = site.latLonAlt();
    try {
        const sky::AziEleDst riseTop = satellite.topPosition(sky::julianFromDate(rise), observer);
        const sky::AziEleDst peakTop = satellite.topPosition(sky::julianFromDate(peak), observer);
        const sky::AziEleDst setTop = satellite.topPosition(sky::julianFromDate(set), observer);

        PassEvent event;
        event.rise = rise;
        event.peak = peak;
        event.set = set;
        event.maxElevation = maxElevation;
        event.riseAzimuth = riseTop.azim;
        event.peakAzimuth = peakTop.azim;
        event.setAzimuth = setTop.azim;
        event.rangeAtPeakKm = peakTop.dist;
        event.isVisible = PassPredictor::isVisible(satellite, peak, site);
        return event;
    } catch (...) {
        return std::nullopt;
    }
}

}  // namespace

std::vector<PassEvent> PassPredictor::passes(const sky::Satellite& satellite,
                                             const ObserverSite& site, Date start,
                                             double hours, double minElevation,
                                             int limit) {
    const double step = scanStep;
    const Date end = start + hours * 3600.0;
    const sky::LatLonAlt observer = site.latLonAlt();

    std::vector<PassEvent> events;
    Date previousTime = start;
    double previousElevation = elevationAt(satellite, observer, start).value_or(-90.0);

    // State for the pass currently being tracked.
    std::optional<Date> riseTime;
    std::optional<Date> peakTime;
    double peakElevation = -90.0;

    Date time = start + step;
    while (time <= end) {
        const std::optional<double> current = elevationAt(satellite, observer, time);
        if (!current) {
            // Propagation failure: abandon the in-flight pass and resync.
            riseTime.reset();
            peakTime.reset();
            peakElevation = -90.0;
            previousTime = time;
            previousElevation = -90.0;
            time += step;
            continue;
        }

        if (!riseTime && previousElevation < minElevation && *current >= minElevation) {
            riseTime = refineCrossing(satellite, observer, previousTime, time, minElevation,
                                      true);
            peakTime.reset();
            peakElevation = *current;
        }

        if (riseTime) {
            if (*current > peakElevation) {
                peakElevation = *current;
                peakTime = time;
            }

            if (previousElevation >= minElevation && *current < minElevation) {
                const Date setTime =
                    refineCrossing(satellite, observer, previousTime, time, minElevation, false);
                if (riseTime && peakTime) {
                    if (const auto event = makeEvent(satellite, site, *riseTime, *peakTime,
                                                     setTime, peakElevation)) {
                        events.push_back(*event);
                        if (static_cast<int>(events.size()) >= limit) return events;
                    }
                }
                riseTime.reset();
                peakTime.reset();
                peakElevation = -90.0;
            }
        }

        previousTime = time;
        previousElevation = *current;
        time += step;
    }

    // A pass still in progress at the end of the window is reported with the
    // window edge as its set time only when it is already past its peak.
    if (riseTime && peakTime && *peakTime > *riseTime) {
        if (const auto event =
                makeEvent(satellite, site, *riseTime, *peakTime, end, peakElevation)) {
            events.push_back(*event);
        }
    }

    return events;
}

bool PassPredictor::isVisible(const sky::Satellite& satellite, Date date,
                              const ObserverSite& site) {
    if (!SunCalculator::isObserverDark(date, site)) return false;
    try {
        const sky::Vec3 eci = satellite.position(sky::julianFromDate(date));
        return SunCalculator::isSunlit(eci, date);
    } catch (...) {
        return false;
    }
}

std::vector<double> PassPredictor::elevationProfile(const sky::Satellite& satellite,
                                                    const ObserverSite& site,
                                                    const PassEvent& pass, int samples) {
    const sky::LatLonAlt observer = site.latLonAlt();
    const double span = pass.set - pass.rise;
    if (!(span > 0.0)) return {};

    std::vector<double> values;
    values.reserve(static_cast<size_t>(samples) + 1);
    for (int i = 0; i <= samples; ++i) {
        const Date date = pass.rise + span * static_cast<double>(i) / static_cast<double>(samples);
        const double elevation =
            elevationAt(satellite, observer, date).value_or(0.0);
        values.push_back(std::max(0.0, elevation));
    }
    return values;
}

}  // namespace caelus

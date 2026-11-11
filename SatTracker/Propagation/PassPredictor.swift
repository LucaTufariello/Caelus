//
//  PassPredictor.swift
//  SatTracker
//
//  Finds visible passes for a ground site over the next N hours.
//
//  A coarse scan finds every threshold crossing, then bisection refines each
//  rise and set to sub-second precision. The scan is deliberately cheap enough
//  to run for the selected satellite plus every favourite without blocking the
//  main actor.
//

import Foundation
import SatelliteKit

/// A single pass over the observer's horizon.
struct PassEvent: Sendable, Identifiable, Equatable {
    let rise: Date
    let peak: Date
    let set: Date
    let maxElevation: Double        // degrees
    let riseAzimuth: Double         // degrees
    let peakAzimuth: Double
    let setAzimuth: Double
    let rangeAtPeakKm: Double
    let isVisible: Bool             // satellite sunlit while the observer is dark

    var id: Date { rise }
    var duration: TimeInterval { self.set.timeIntervalSince(rise) }

    /// Compass point for the peak azimuth.
    var peakDirection: String { Compass.direction(for: peakAzimuth) }
    var riseDirection: String { Compass.direction(for: riseAzimuth) }
    var setDirection: String { Compass.direction(for: setAzimuth) }
}

enum Compass {
    static let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    static func direction(for azimuth: Double) -> String {
        var value = azimuth.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        let index = Int((value / 22.5).rounded()) % 16
        return names[index]
    }
}

enum PassPredictor {

    /// Default scan resolution. A 30 s grid cannot miss a pass that clears the
    /// horizon for more than a minute, which covers every useful pass.
    static let scanStep: TimeInterval = 30

    /// Predict passes for one satellite.
    ///
    /// - Parameters:
    ///   - satellite: Propagator built from the record's elements.
    ///   - site: Observer.
    ///   - start: Beginning of the search window.
    ///   - hours: Length of the window.
    ///   - minElevation: Peak elevation a pass must reach to be reported.
    ///   - limit: Stop after this many passes.
    static func passes(satellite: Satellite,
                       site: ObserverSite,
                       from start: Date = Date(),
                       hours: Double = 48,
                       minElevation: Double = 10,
                       limit: Int = 50) -> [PassEvent] {
        let step = scanStep
        let end = start.addingTimeInterval(hours * 3600)
        let observer = site.latLonAlt

        func elevation(at date: Date) -> Double? {
            try? satellite.topPosition(julianDays: date.julianDate, observer: observer).elev
        }

        var events: [PassEvent] = []
        var previousTime = start
        var previousElevation = elevation(at: start) ?? -90

        // State for the pass currently being tracked.
        var riseTime: Date?
        var peakTime: Date?
        var peakElevation: Double = -90

        var time = start.addingTimeInterval(step)
        while time <= end {
            guard let current = elevation(at: time) else {
                // Propagation failure: abandon the in-flight pass and resync.
                riseTime = nil
                peakTime = nil
                peakElevation = -90
                previousTime = time
                previousElevation = -90
                time = time.addingTimeInterval(step)
                continue
            }

            if riseTime == nil, previousElevation < minElevation, current >= minElevation {
                riseTime = refineCrossing(satellite: satellite, observer: observer,
                                          from: previousTime, to: time,
                                          threshold: minElevation, rising: true)
                peakTime = nil
                peakElevation = current
            }

            if riseTime != nil {
                if current > peakElevation {
                    peakElevation = current
                    peakTime = time
                }

                if previousElevation >= minElevation, current < minElevation {
                    let setTime = refineCrossing(satellite: satellite, observer: observer,
                                                 from: previousTime, to: time,
                                                 threshold: minElevation, rising: false)
                    if let rise = riseTime, let peak = peakTime {
                        if let event = makeEvent(satellite: satellite, site: site,
                                                 rise: rise, peak: peak, set: setTime,
                                                 maxElevation: peakElevation) {
                            events.append(event)
                            if events.count >= limit { return events }
                        }
                    }
                    riseTime = nil
                    peakTime = nil
                    peakElevation = -90
                }
            }

            previousTime = time
            previousElevation = current
            time = time.addingTimeInterval(step)
        }

        // A pass still in progress at the end of the window is reported with the
        // window edge as its set time only when it is already past its peak.
        if let rise = riseTime, let peak = peakTime, peak > rise {
            if let event = makeEvent(satellite: satellite, site: site,
                                     rise: rise, peak: peak, set: end,
                                     maxElevation: peakElevation) {
                events.append(event)
            }
        }

        return events
    }

    // MARK: - Refinement

    /// Bisection between two samples that straddle the threshold.
    private static func refineCrossing(satellite: Satellite,
                                       observer: LatLonAlt,
                                       from lower: Date,
                                       to upper: Date,
                                       threshold: Double,
                                       rising: Bool) -> Date {
        var lo = lower
        var hi = upper
        for _ in 0..<24 {
            let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
            guard let elevation = try? satellite.topPosition(julianDays: mid.julianDate,
                                                             observer: observer).elev else {
                break
            }
            let above = elevation >= threshold
            if above == rising { hi = mid } else { lo = mid }
        }
        return lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
    }

    private static func makeEvent(satellite: Satellite,
                                  site: ObserverSite,
                                  rise: Date,
                                  peak: Date,
                                  set: Date,
                                  maxElevation: Double) -> PassEvent? {
        let observer = site.latLonAlt
        guard let riseTop = try? satellite.topPosition(julianDays: rise.julianDate, observer: observer),
              let peakTop = try? satellite.topPosition(julianDays: peak.julianDate, observer: observer),
              let setTop = try? satellite.topPosition(julianDays: set.julianDate, observer: observer)
        else { return nil }

        let visible = isVisible(satellite: satellite, at: peak, site: site)

        return PassEvent(rise: rise,
                         peak: peak,
                         set: set,
                         maxElevation: maxElevation,
                         riseAzimuth: riseTop.azim,
                         peakAzimuth: peakTop.azim,
                         setAzimuth: setTop.azim,
                         rangeAtPeakKm: peakTop.dist,
                         isVisible: visible)
    }

    /// Naked-eye visibility: the satellite is in sunlight while the observer is
    /// past civil twilight.
    static func isVisible(satellite: Satellite, at date: Date, site: ObserverSite) -> Bool {
        guard SunCalculator.isObserverDark(at: date, site: site) else { return false }
        guard let eci = try? satellite.position(julianDays: date.julianDate) else { return false }
        return SunCalculator.isSunlit(satelliteECI: eci, at: date)
    }

    // MARK: - Elevation profile

    /// Sample the elevation curve across a pass, for the sparkline in the UI.
    static func elevationProfile(satellite: Satellite,
                                 site: ObserverSite,
                                 pass: PassEvent,
                                 samples: Int = 48) -> [Double] {
        let observer = site.latLonAlt
        let span = pass.set.timeIntervalSince(pass.rise)
        guard span > 0 else { return [] }
        var values: [Double] = []
        values.reserveCapacity(samples)
        for i in 0...samples {
            let date = pass.rise.addingTimeInterval(span * Double(i) / Double(samples))
            let elevation = (try? satellite.topPosition(julianDays: date.julianDate,
                                                        observer: observer).elev) ?? 0
            values.append(max(0, elevation))
        }
        return values
    }
}

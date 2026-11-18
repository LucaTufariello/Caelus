//
//  SatelliteInspector.swift
//  Caelus
//
//  Everything known about the selected object, in one column: identity, live
//  state, geometry relative to the ground station, the orbital elements the
//  propagator is actually using, and the next passes.
//

import SwiftUI

struct SatelliteInspector: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let record = model.selectedRecord {
                header(record)
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        statusRow(record)
                        Hairline()
                        liveSection
                        Hairline()
                        observerSection
                        Hairline()
                        elementsSection(record)
                        Hairline()
                        passesSection
                    }
                }
                .scrollIndicators(.visible)
            } else {
                placeholder
            }
        }
        .frame(width: Theme.inspectorWidth)
        .background(Theme.surface)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    // MARK: - Header

    private func header(_ record: SatelliteRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name)
                    .font(Theme.text(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    Text("\(record.id)")
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text("·")
                        .foregroundStyle(Theme.textDisabled)
                    Text(record.cosparID)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                    Text("·")
                        .foregroundStyle(Theme.textDisabled)
                    Text(record.renderGroup.title)
                        .font(Theme.text(10))
                        .foregroundStyle(record.renderGroup.color.opacity(0.9))
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                IconButton(systemName: model.isFavorite(record.id) ? "star.fill" : "star",
                           help: model.isFavorite(record.id) ? "Remove from favorites (⌘D)"
                                                             : "Add to favorites (⌘D)",
                           isActive: model.isFavorite(record.id)) {
                    model.toggleFavorite(record.id)
                }
                IconButton(systemName: "xmark", help: "Clear selection (esc)") {
                    model.select(nil)
                }
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Status pills

    private func statusRow(_ record: SatelliteRecord) -> some View {
        HStack(spacing: 6) {
            if let state = model.selectedState {
                Pill(text: regime(for: state.altitudeKm),
                     color: record.renderGroup.color)
                Pill(text: state.sunlit ? "SUNLIT" : "ECLIPSE",
                     color: state.sunlit ? Theme.warning : Theme.textTertiary)
                if let elevation = state.elevationFromObserver, elevation > 0 {
                    Pill(text: "ABOVE HORIZON", color: Theme.success, pulsing: true)
                }
            } else {
                Pill(text: "ACQUIRING", color: Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func regime(for altitudeKm: Double) -> String {
        switch altitudeKm {
        case ..<2_000: "LEO"
        case ..<35_000: "MEO"
        case ..<36_500: "GEO"
        default: "HIGH"
        }
    }

    // MARK: - Live state

    private var liveSection: some View {
        let state = model.selectedState
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Live state")
            MetricGrid(metrics: [
                Metric(label: "Altitude",
                       value: state.map { Formatters.altitude($0.altitudeKm) } ?? "—",
                       unit: "km"),
                Metric(label: "Velocity",
                       value: state.map { Formatters.speed($0.velocityKmS) } ?? "—",
                       unit: "km/s"),
                Metric(label: "Latitude",
                       value: state.map { coordinate($0.latitude, positive: "N", negative: "S") } ?? "—"),
                Metric(label: "Longitude",
                       value: state.map { coordinate($0.longitude, positive: "E", negative: "W") } ?? "—"),
            ])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func coordinate(_ value: Double, positive: String, negative: String) -> String {
        String(format: "%.2f° %@", abs(value), value >= 0 ? positive : negative)
    }

    // MARK: - Observer geometry

    private var observerSection: some View {
        let state = model.selectedState
        let site = model.observer

        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("From \(site.name)", trailing: site.formattedCoordinate)
            MetricGrid(metrics: [
                Metric(label: "Range",
                       value: state?.rangeToObserverKm.map { Formatters.distance($0) } ?? "—",
                       unit: "km"),
                Metric(label: "Elevation",
                       value: state?.elevationFromObserver.map { Formatters.signedDegrees($0) } ?? "—",
                       tint: elevationTint(state?.elevationFromObserver)),
                Metric(label: "Azimuth",
                       value: state?.azimuthFromObserver.map {
                           String(format: "%.0f° %@", $0, Compass.direction(for: $0))
                       } ?? "—"),
                Metric(label: "Next rise",
                       value: nextRiseText,
                       tint: model.passes.isEmpty ? Theme.textPrimary : Theme.accent),
            ])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Time to the next rise, or "—" when nothing is predicted in the window.
    private var nextRiseText: String {
        guard let rise = model.passes.first?.rise else { return "—" }
        let seconds = rise.timeIntervalSince(model.lastTick ?? Date())
        return seconds > 0 ? "in " + Formatters.countdown(seconds) : "now"
    }

    private func elevationTint(_ elevation: Double?) -> Color {
        guard let elevation else { return Theme.textPrimary }
        if elevation > 10 { return Theme.success }
        if elevation > 0 { return Theme.warning }
        return Theme.textSecondary
    }

    // MARK: - Elements

    private func elementsSection(_ record: SatelliteRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Orbital elements", trailing: "TLE epoch")
            MetricGrid(metrics: [
                Metric(label: "Inclination",
                       value: Formatters.degrees(record.inclinationDeg, decimals: 2)),
                Metric(label: "Period",
                       value: String(format: "%.1f", record.periodMinutes),
                       unit: "min"),
                Metric(label: "Eccentricity",
                       value: String(format: "%.5f", record.eccentricity)),
                Metric(label: "RAAN",
                       value: Formatters.degrees(record.raanDeg, decimals: 2)),
                Metric(label: "Apogee",
                       value: Formatters.altitude(record.apogeeKm),
                       unit: "km"),
                Metric(label: "Perigee",
                       value: Formatters.altitude(record.perigeeKm),
                       unit: "km"),
                Metric(label: "Arg. perigee",
                       value: Formatters.degrees(record.argumentOfPerigeeDeg, decimals: 2)),
                Metric(label: "Element age",
                       value: Formatters.age(record.age(at: model.lastTick ?? Date())),
                       tint: record.age(at: Date()) > 24 * 3600 ? Theme.warning : Theme.textPrimary),
            ])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Passes

    private var passesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Next passes", trailing: "24 h · ≥10°")
                if model.isLoadingPasses {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.accent)
                }
            }
            PassesView(passes: model.passes,
                       site: model.observer,
                       isLoading: model.isLoadingPasses)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "scope")
                .font(.system(size: 26, weight: .ultraLight))
                .foregroundStyle(Theme.textDisabled)
            VStack(spacing: 4) {
                Text("No object selected")
                    .font(Theme.text(12.5, .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("Pick a satellite from the list or click one on the globe to see its state, orbit and passes.")
                    .font(Theme.text(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 230)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}

// MARK: - Metric grid

private struct Metric: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var unit: String?
    var tint: Color = Theme.textPrimary
}

private struct MetricGrid: View {
    let metrics: [Metric]

    private let columns = [
        GridItem(.flexible(minimum: 0), spacing: 10, alignment: .leading),
        GridItem(.flexible(minimum: 0), spacing: 10, alignment: .leading),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 11) {
            ForEach(metrics) { metric in
                TelemetryRow(label: metric.label,
                             value: metric.value,
                             unit: metric.unit,
                             tint: metric.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Pill

private struct Pill: View {
    let text: String
    var color: Color
    var pulsing: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if pulsing {
                StatusDot(color: color, size: 4, pulsing: true)
            }
            Text(text)
                .font(Theme.text(9, .semibold))
                .tracking(0.7)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(0.11))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: 1)
        }
    }
}

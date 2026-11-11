//
//  SettingsView.swift
//  SatTracker
//
//  Ground station, display options, and the state of the local element cache.
//

import SwiftUI

struct SettingsView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ObserverSite = .rome
    @State private var didSeed = false

    private static let presets: [ObserverSite] = [
        .rome,
        ObserverSite(name: "London", latitude: 51.5074, longitude: -0.1278),
        ObserverSite(name: "New York", latitude: 40.7128, longitude: -74.0060),
        ObserverSite(name: "Tokyo", latitude: 35.6762, longitude: 139.6503),
        ObserverSite(name: "Sydney", latitude: -33.8688, longitude: 151.2093),
        ObserverSite(name: "Nairobi", latitude: -1.2921, longitude: 36.8219),
    ]

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    stationSection
                    Hairline()
                    displaySection
                    Hairline()
                    dataSection
                    Hairline()
                    diagnosticsSection
                }
            }
            .scrollIndicators(.visible)
        }
        .frame(width: 520, height: 600)
        .background(Theme.surface)
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            draft = model.observer
        }
    }

    // MARK: - Title

    private var titleBar: some View {
        HStack {
            Text("Settings")
                .font(Theme.text(13, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            IconButton(systemName: "xmark", help: "Close") { dismiss() }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    // MARK: - Ground station

    private var stationSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel("Ground station", trailing: model.observer.formattedCoordinate)

            FlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(Self.presets, id: \.name) { preset in
                    Chip(title: preset.name,
                         color: Theme.accent,
                         isOn: isCurrent(preset)) {
                        draft = preset
                        model.setObserver(preset)
                    }
                }
            }

            HStack(spacing: 9) {
                field("Name", text: $draft.name)
                field("Latitude", value: $draft.latitude, format: "%.4f")
                field("Longitude", value: $draft.longitude, format: "%.4f")
                field("Altitude", value: $draft.altitudeKm, format: "%.2f")
            }

            HStack(spacing: 8) {
                Text("Custom coordinates are applied to the globe, pass predictions and observer geometry.")
                    .font(Theme.text(10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button("Apply") {
                    model.setObserver(clamped(draft))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isDirty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func isCurrent(_ preset: ObserverSite) -> Bool {
        abs(model.observer.latitude - preset.latitude) < 1e-6
            && abs(model.observer.longitude - preset.longitude) < 1e-6
    }

    private var isDirty: Bool {
        let applied = model.observer
        return draft.name != applied.name
            || abs(draft.latitude - applied.latitude) > 1e-6
            || abs(draft.longitude - applied.longitude) > 1e-6
            || abs(draft.altitudeKm - applied.altitudeKm) > 1e-6
    }

    private func clamped(_ site: ObserverSite) -> ObserverSite {
        ObserverSite(name: site.name.isEmpty ? "Custom" : site.name,
                     latitude: min(89.9, max(-89.9, site.latitude)),
                     longitude: site.longitude.truncatingRemainder(dividingBy: 360),
                     altitudeKm: min(9, max(-0.5, site.altitudeKm)))
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Theme.text(8.5, .medium))
                .tracking(0.7)
                .foregroundStyle(Theme.textTertiary)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 7)
                .frame(height: 25)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.surfaceRaised)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ label: String,
                       value: Binding<Double>,
                       format: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Theme.text(8.5, .medium))
                .tracking(0.7)
                .foregroundStyle(Theme.textTertiary)
            TextField("", value: value, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.plain)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 7)
                .frame(height: 25)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.surfaceRaised)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Display

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Display")

            toggleRow("Orbit path",
                      detail: "The selected satellite's inertial trajectory",
                      isOn: Binding(get: { model.showOrbitPath },
                                    set: { model.setShowOrbitPath($0) }))
            toggleRow("Ground track",
                      detail: "Sub-satellite path, past dim and future bright",
                      isOn: Binding(get: { model.showGroundTrack },
                                    set: { model.setShowGroundTrack($0) }))
            toggleRow("Ground station",
                      detail: "Observer marker and horizon circle",
                      isOn: Binding(get: { model.showObserver },
                                    set: { model.setShowObserver($0) }))

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Point size")
                        .font(Theme.text(11.5, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Scales every satellite marker")
                        .font(Theme.text(10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 12)
                Slider(value: Binding(get: { model.pointSize },
                                      set: { model.setPointSize($0) }),
                       in: 0.5...2.5)
                    .frame(width: 150)
                    .controlSize(.small)
                Text(String(format: "%.1f×", model.pointSize))
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func toggleRow(_ title: String,
                           detail: String,
                           isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.text(11.5, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.text(10))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Element data", trailing: provenanceLabel)

            HStack(spacing: 0) {
                TelemetryRow(label: "Objects",
                             value: Formatters.compact(model.catalog.count))
                TelemetryRow(label: "Cache",
                             value: ByteCountFormatter.string(fromByteCount: Int64(model.cacheBytes),
                                                              countStyle: .file))
                TelemetryRow(label: "Last check",
                             value: model.lastRefresh.map { DateFormatters.utc.string(from: $0) } ?? "—")
                TelemetryRow(label: "Groups",
                             value: "\(model.groupMeta.count)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !model.groupMeta.isEmpty {
                VStack(spacing: 2) {
                    ForEach(model.groupMeta.sorted(by: { $0.key < $1.key }), id: \.key) { key, meta in
                        HStack(spacing: 8) {
                            Text(key)
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text("\(meta.count)")
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.textTertiary)
                            Text(DateFormatters.utc.string(from: meta.fetchedAt))
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.textDisabled)
                                .frame(width: 62, alignment: .trailing)
                        }
                    }
                }
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.surfaceRaised.opacity(0.6))
                }
            }

            HStack(spacing: 8) {
                Button("Refresh now") { model.refresh(force: true) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isRefreshing)

                Button("Clear cache") { model.clearCache() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Theme.accent)
                }

                Spacer()
            }

            if let message = model.statusMessage {
                Text(message)
                    .font(Theme.text(10))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var provenanceLabel: String {
        switch model.provenance {
        case .celestrak: "CelesTrak GP"
        case .satnogs: "SatNOGS"
        case .cache: "Local cache"
        case .synthetic: "Synthetic (QA)"
        case .none: "No data"
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Diagnostics", trailing: model.diagnostics.isEmpty ? "Clean" : "Attention")

            HStack(spacing: 0) {
                TelemetryRow(label: "Parse failures",
                             value: "\(model.diagnostics.parseFailures)",
                             tint: model.diagnostics.parseFailures > 0 ? Theme.warning : Theme.textPrimary)
                TelemetryRow(label: "Duplicates merged",
                             value: "\(model.diagnostics.duplicateRecords)")
                TelemetryRow(label: "Unpropagatable",
                             value: "\(model.diagnostics.unpropagatable)",
                             tint: model.diagnostics.unpropagatable > 0 ? Theme.warning : Theme.textPrimary)
                TelemetryRow(label: "SGP4 tick",
                             value: String(format: "%.0f ms", model.snapshotDuration * 1_000))
            }

            if !model.diagnostics.messages.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.diagnostics.messages.prefix(6).enumerated()), id: \.offset) { _, message in
                        Text(message)
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if !model.diagnostics.failedGroups.isEmpty {
                Text("Unavailable groups: " + model.diagnostics.failedGroups.joined(separator: ", "))
                    .font(Theme.text(10))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

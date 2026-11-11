//
//  StatusBar.swift
//  SatTracker
//
//  A single line of live telemetry across the bottom of the globe.
//

import SwiftUI

struct StatusBar: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            source
            separator
            objects
            separator
            performance
            separator
            clock
            separator
            site
            if model.isRefreshing {
                separator
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.accent)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 14, y: 5)
        .animation(.easeOut(duration: 0.2), value: model.isRefreshing)
    }

    // MARK: - Segments

    private var source: some View {
        HStack(spacing: 6) {
            StatusDot(color: sourceColor, size: 5, pulsing: model.provenance == .celestrak)
            Text(sourceLabel)
                .font(Theme.text(10, .semibold))
                .tracking(0.6)
                .foregroundStyle(sourceColor)
        }
    }

    private var objects: some View {
        HStack(spacing: 4) {
            Text(Formatters.compact(model.catalog.count))
                .font(Theme.mono(10.5, .medium))
                .foregroundStyle(Theme.textPrimary)
            Text("objects")
                .font(Theme.text(10))
                .foregroundStyle(Theme.textTertiary)
            if model.visibleCount != model.catalog.count {
                Text("· \(Formatters.compact(model.visibleCount)) shown")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var performance: some View {
        HStack(spacing: 4) {
            Text("SGP4")
                .font(Theme.text(9.5, .medium))
                .tracking(0.4)
                .foregroundStyle(Theme.textTertiary)
            Text(String(format: "%.0f ms", model.snapshotDuration * 1_000))
                .font(Theme.mono(10.5))
                .foregroundStyle(model.snapshotDuration > 0.25 ? Theme.warning : Theme.textSecondary)
            if model.propagationFailures > 0 {
                Text("· \(model.propagationFailures) skipped")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    private var clock: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 8.5))
                .foregroundStyle(Theme.textTertiary)
            Text(model.lastTick.map { DateFormatters.utc.string(from: $0) } ?? "—")
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var site: some View {
        HStack(spacing: 5) {
            Image(systemName: "location.fill")
                .font(.system(size: 8))
                .foregroundStyle(Theme.textTertiary)
            Text(model.observer.name)
                .font(Theme.text(10.5, .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.hairlineStrong)
            .frame(width: 1, height: 11)
            .padding(.horizontal, 11)
    }

    // MARK: - Labels

    private var sourceLabel: String {
        switch model.provenance {
        case .celestrak: "LIVE"
        case .satnogs: "SATNOGS"
        case .cache: "CACHED"
        case .none: "OFFLINE"
        }
    }

    private var sourceColor: Color {
        switch model.provenance {
        case .celestrak: Theme.success
        case .satnogs: Theme.warning
        case .cache: Theme.accent
        case .none: Theme.textTertiary
        }
    }
}

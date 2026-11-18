//
//  PassesView.swift
//  Caelus
//
//  Predicted passes for the selected satellite over the ground station.
//

import SwiftUI

struct PassesView: View {

    let passes: [PassEvent]
    let site: ObserverSite
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 4) {
            if passes.isEmpty {
                empty
            } else {
                ForEach(passes) { pass in
                    PassRow(pass: pass, reference: Date())
                }
            }
        }
    }

    private var empty: some View {
        HStack(spacing: 7) {
            Image(systemName: isLoading ? "hourglass" : "moon.zzz")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDisabled)
            Text(isLoading
                 ? "Scanning the next 24 hours…"
                 : "No pass above 10° in the next 24 hours.")
                .font(Theme.text(10.5))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Row

private struct PassRow: View {

    let pass: PassEvent
    let reference: Date

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            // Elevation gauge: taller and brighter for a higher pass.
            Capsule()
                .fill(elevationColor.opacity(0.85))
                .frame(width: 2.5, height: 26)
                .opacity(0.35 + 0.65 * min(1, pass.maxElevation / 90))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(DateFormatters.shortTime.string(from: pass.rise))
                        .font(Theme.mono(11, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("→")
                        .font(Theme.text(9))
                        .foregroundStyle(Theme.textDisabled)
                    Text(DateFormatters.shortTime.string(from: pass.set))
                        .font(Theme.mono(11, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if pass.isVisible {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 7.5))
                            .foregroundStyle(Theme.warning)
                            .help("Satellite is sunlit while the sky is dark")
                    }
                }
                Text("\(Formatters.duration(pass.duration)) · \(pass.riseDirection) → \(pass.setDirection)")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Formatters.degrees(pass.maxElevation, decimals: 0))
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(elevationColor)
                Text(relativeStart)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovering ? Theme.surfaceHover : Theme.surfaceRaised.opacity(0.5))
        }
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover { hovering = $0 }
        .help("Peak \(Formatters.degrees(pass.maxElevation)) at \(DateFormatters.shortTime.string(from: pass.peak)) · closest \(Formatters.distance(pass.rangeAtPeakKm)) km")
    }

    private var elevationColor: Color {
        switch pass.maxElevation {
        case 45...: Theme.success
        case 20..<45: Theme.accent
        default: Theme.textSecondary
        }
    }

    private var relativeStart: String {
        let seconds = pass.rise.timeIntervalSince(reference)
        if seconds <= 0 { return "in progress" }
        if seconds < 3600 { return "in \(Int(seconds / 60))m" }
        return "in \(String(format: "%.1f", seconds / 3600))h"
    }
}

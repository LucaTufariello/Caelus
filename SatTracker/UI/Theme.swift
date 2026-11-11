//
//  Theme.swift
//  SatTracker
//
//  The app's visual language: a dark, low-chroma instrument panel with a single
//  azure accent, hairline separators and monospaced numerals for anything that
//  is telemetry rather than prose.
//

import SwiftUI

// MARK: - Palette

enum Theme {

    // Surfaces
    static let background = Color(hex: 0x06090E)
    static let surface = Color(hex: 0x0A0E15)
    static let surfaceRaised = Color(hex: 0x10161F)
    static let surfaceHover = Color(hex: 0x161E29)
    static let globeBackdrop = Color(hex: 0x03050A)

    // Lines
    static let hairline = Color.white.opacity(0.065)
    static let hairlineStrong = Color.white.opacity(0.12)

    // Text
    static let textPrimary = Color(hex: 0xE8EDF5)
    static let textSecondary = Color(hex: 0x8B98AA)
    static let textTertiary = Color(hex: 0x5A6678)
    static let textDisabled = Color(hex: 0x3E4857)

    // Accents
    static let accent = Color(hex: 0x4FB3FF)
    static let accentSoft = Color(hex: 0x4FB3FF).opacity(0.14)
    static let warning = Color(hex: 0xFFB454)
    static let danger = Color(hex: 0xFF6B6B)
    static let success = Color(hex: 0x3DDC97)

    // MARK: Type

    /// Telemetry numerals: monospaced so digits do not jitter as they change.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: Metrics

    static let cornerRadius: CGFloat = 8
    static let cornerRadiusSmall: CGFloat = 6
    static let panelPadding: CGFloat = 14
    static let sidebarWidth: CGFloat = 316
    static let inspectorWidth: CGFloat = 348
}

// MARK: - Group colours

extension SatelliteGroup {
    var color: Color {
        switch self {
        case .stations: Color(hex: 0xF2F6FF)
        case .starlink: Color(hex: 0x4D9BFF)
        case .navigation: Color(hex: 0x3DDC97)
        case .weather: Color(hex: 0xFFB454)
        case .science: Color(hex: 0xB58CFF)
        case .other: Color(hex: 0x6E7D92)
        }
    }

    /// Point size multiplier: the 10k-strong constellation is drawn finer so it
    /// reads as a field rather than a wall of dots.
    var pointScale: CGFloat {
        switch self {
        case .stations: 1.5
        case .starlink: 0.72
        case .navigation: 1.0
        case .weather: 1.0
        case .science: 1.05
        case .other: 0.85
        }
    }
}

// MARK: - Colour helpers

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Building blocks

/// A small uppercase section heading with wide tracking.
struct SectionLabel: View {
    let text: String
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text.uppercased())
                .font(Theme.text(9.5, .semibold))
                .tracking(1.1)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// A hairline that survives on both dark and light vibrancy.
struct Hairline: View {
    var inset: CGFloat = 0
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// Label above, monospaced value below — the inspector's basic unit.
struct TelemetryRow: View {
    let label: String
    let value: String
    var unit: String?
    var tint: Color = Theme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Theme.text(9, .medium))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.mono(13, .medium))
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit)
                        .font(Theme.text(10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

/// A rounded chip used for group filters and tags.
struct Chip: View {
    let title: String
    var color: Color = Theme.accent
    var count: Int?
    var isOn: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isOn ? color : Theme.textDisabled)
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(Theme.text(10.5, .medium))
                    .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary)
                if let count {
                    Text(Formatters.compact(count))
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? color.opacity(0.13) : (hovering ? Theme.surfaceHover : Color.clear))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(isOn ? color.opacity(0.35) : Theme.hairline, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

/// A small coloured status dot, optionally pulsing.
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 6
    var pulsing: Bool = false

    @State private var pulse = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: size * 2.4, height: size * 2.4)
                    .scaleEffect(pulse ? 1.0 : 0.55)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2.4, height: size * 2.4)
        .onAppear { pulse = true }
    }
}

/// A bordered panel used for floating HUD blocks over the globe.
struct HUDPanel<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .stroke(Theme.hairlineStrong, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

/// A flat icon button that reads as a tool, not a control.
struct IconButton: View {
    let systemName: String
    var help: String = ""
    var isActive: Bool = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : (hovering ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: 26, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering || isActive ? Theme.surfaceHover : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Formatting

enum Formatters {

    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<10_000: String(format: "%.1fk", Double(value) / 1_000)
        case ..<1_000_000: String(format: "%.0fk", Double(value) / 1_000)
        default: String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }

    static func altitude(_ km: Double) -> String {
        if km >= 10_000 { return String(format: "%.0f", km) }
        if km >= 1_000 { return String(format: "%.1f", km) }
        return String(format: "%.0f", km)
    }

    static func speed(_ kmS: Double) -> String {
        String(format: "%.2f", kmS)
    }

    static func distance(_ km: Double) -> String {
        if km >= 100_000 { return String(format: "%.0f", km) }
        if km >= 1_000 { return String(format: "%.0f", km) }
        return String(format: "%.1f", km)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        if minutes >= 60 {
            return String(format: "%dh %02dm", minutes / 60, minutes % 60)
        }
        return String(format: "%dm %02ds", minutes, secs)
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func age(_ interval: TimeInterval) -> String {
        let hours = interval / 3600
        if abs(hours) < 1 { return String(format: "%.0f min", abs(interval) / 60) }
        if abs(hours) < 48 { return String(format: "%.1f h", hours) }
        return String(format: "%.1f d", hours / 24)
    }

    static func degrees(_ value: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f°", value)
    }

    static func signedDegrees(_ value: Double, decimals: Int = 2) -> String {
        String(format: "%+.\(decimals)f°", value)
    }

    static func coordinate(lat: Double, lon: Double) -> String {
        let ns = lat >= 0 ? "N" : "S"
        let ew = lon >= 0 ? "E" : "W"
        return String(format: "%.2f°%@  %.2f°%@", abs(lat), ns, abs(lon), ew)
    }
}

// MARK: - Date formatting

enum DateFormatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_GB")
        return formatter
    }()

    static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_GB")
        return formatter
    }()

    static let utc: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        return formatter
    }()

    static let dayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM · HH:mm"
        formatter.locale = Locale(identifier: "en_GB")
        return formatter
    }()

    static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        return formatter
    }()
}

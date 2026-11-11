//
//  SidebarView.swift
//  SatTracker
//
//  The catalog browser: search, group filters, and the object list.
//
//  The list is a `LazyVStack` inside a `ScrollView`, so a 16 000-row catalog
//  costs only the rows on screen. Each row reads the live snapshot itself rather
//  than being handed a value from the parent, which keeps the one-hertz tick
//  from re-evaluating the whole list.
//

import SwiftUI

struct SidebarView: View {

    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    @State private var showingSettings = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            brand
            Hairline()

            VStack(spacing: 10) {
                searchField
                groupChips
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 11)

            Hairline()
            listHeader
            objectList
            Hairline()
            footer
        }
        .frame(width: Theme.sidebarWidth)
        .background(Theme.surface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .onChange(of: model.searchFocusToken) { _, _ in
            searchFocused = true
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environment(model)
        }
    }

    // MARK: - Brand

    private var brand: some View {
        HStack(spacing: 9) {
            ReticleMark()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("SATTRACKER")
                    .font(Theme.text(11.5, .semibold))
                    .tracking(1.6)
                    .foregroundStyle(Theme.textPrimary)
                Text("Orbital situational awareness")
                    .font(Theme.text(9.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 0)

            StatusDot(color: provenanceColor,
                      size: 5,
                      pulsing: model.provenance == .celestrak)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    private var provenanceColor: Color {
        switch model.provenance {
        case .celestrak: Theme.success
        case .satnogs: Theme.warning
        case .cache: Theme.accent
        case .synthetic: Theme.danger
        case .none: Theme.textTertiary
        }
    }

    // MARK: - Search

    private var searchField: some View {
        @Bindable var model = model

        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(searchFocused ? Theme.accent : Theme.textTertiary)

            TextField("Search name or NORAD ID", text: $model.query)
                .textFieldStyle(.plain)
                .font(Theme.text(12))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.surfaceRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(searchFocused ? Theme.accent.opacity(0.55) : Theme.hairline,
                              lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.12), value: searchFocused)
    }

    // MARK: - Filters

    private var groupChips: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            ForEach(SatelliteGroup.allCases) { group in
                Chip(title: group.title,
                     color: group.color,
                     count: model.catalog.count(in: group),
                     isOn: model.activeGroups.contains(group)) {
                    model.setGroup(group, enabled: !model.activeGroups.contains(group))
                }
            }
        }
    }

    // MARK: - List header

    private var listHeader: some View {
        let results = model.searchResults
        return HStack(spacing: 6) {
            SectionLabel(model.query.isEmpty && !model.favoritesOnly ? "Catalog" : "Results")
            Spacer(minLength: 4)
            Text(Formatters.compact(results.count))
                .font(Theme.mono(9.5, .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 6)
    }

    // MARK: - List

    private var objectList: some View {
        let results = model.searchResults
        let selected = model.selectedIndex

        return ScrollView {
            LazyVStack(spacing: 1) {
                if results.isEmpty {
                    emptyResults
                } else {
                    ForEach(results, id: \.self) { index in
                        if let record = model.record(for: index) {
                            SatelliteRow(index: index,
                                         record: record,
                                         isSelected: index == selected,
                                         onSelect: { model.select(index, fly: true) })
                        }
                    }
                }
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.visible)
        .frame(maxHeight: .infinity)
    }

    private var emptyResults: some View {
        VStack(spacing: 8) {
            Image(systemName: model.favoritesOnly ? "star" : "magnifyingglass")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.textDisabled)
            Text(model.favoritesOnly ? "No favorites match" : "No satellites match")
                .font(Theme.text(11.5, .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(model.query.isEmpty
                 ? "Enable a group filter to see objects."
                 : "Try a name, a NORAD number, or a different filter.")
                .font(Theme.text(10.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .padding(.horizontal, 24)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.favoritesOnly.toggle()
                model.invalidateSearch()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.favoritesOnly ? "star.fill" : "star")
                        .font(.system(size: 10, weight: .medium))
                    Text("Favorites")
                        .font(Theme.text(10.5, .medium))
                    if !model.favorites.isEmpty {
                        Text("\(model.favorites.count)")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .foregroundStyle(model.favoritesOnly ? Theme.warning : Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(model.favoritesOnly ? Theme.warning.opacity(0.13) : Color.clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(model.favoritesOnly ? Theme.warning.opacity(0.35) : Theme.hairline,
                                      lineWidth: 1)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.accent)
            }

            IconButton(systemName: "arrow.clockwise",
                       help: "Refresh elements (⌘R)") {
                model.refresh(force: true)
            }
            .disabled(model.isRefreshing)

            IconButton(systemName: "gearshape",
                       help: "Settings") {
                showingSettings = true
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }
}

// MARK: - Row

private struct SatelliteRow: View {

    @Environment(AppModel.self) private var model

    let index: Int
    let record: SatelliteRecord
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        let altitude = model.altitudeKm(for: index)
        let favorite = model.isFavorite(record.id)

        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(record.renderGroup.color)
                    .frame(width: 5, height: 5)
                    .opacity(isSelected ? 1 : 0.85)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(record.name)
                        .font(Theme.text(11.5, isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textPrimary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 4) {
                        Text("\(record.id)")
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.textTertiary)
                        Text("·")
                            .font(Theme.text(9))
                            .foregroundStyle(Theme.textDisabled)
                        Text(record.renderGroup.title)
                            .font(Theme.text(9))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .lineLimit(1)
                }

                Spacer(minLength: 4)

                if favorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.warning)
                }

                if let altitude {
                    Text(Formatters.altitude(altitude))
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft
                          : (hovering ? Theme.surfaceHover : Color.clear))
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.accent)
                        .frame(width: 2.5)
                        .padding(.vertical, 5)
                        .padding(.leading, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Flow layout

/// Wraps children onto as many lines as the width requires. Used for the group
/// chips, which must reflow as the window narrows.
struct FlowLayout: Layout {

    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: maxWidth.isFinite ? maxWidth : max(0, x - spacing),
                      height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Reticle mark

/// The app's mark: a tracking reticle with a plotted object.
private struct ReticleMark: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2

            var ring = Path()
            ring.addArc(center: center, radius: radius,
                        startAngle: .degrees(0), endAngle: .degrees(360),
                        clockwise: false)
            context.stroke(ring, with: .color(Theme.accent.opacity(0.55)), lineWidth: 1)

            var ticks = Path()
            for angle in stride(from: 0.0, to: 360.0, by: 90.0) {
                let radians = angle * .pi / 180
                let inner = CGPoint(x: center.x + cos(radians) * (radius - 2.6),
                                    y: center.y + sin(radians) * (radius - 2.6))
                let outer = CGPoint(x: center.x + cos(radians) * radius,
                                    y: center.y + sin(radians) * radius)
                ticks.move(to: inner)
                ticks.addLine(to: outer)
            }
            context.stroke(ticks, with: .color(Theme.accent.opacity(0.75)), lineWidth: 1)

            let dot = CGRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2)
            context.fill(Path(ellipseIn: dot), with: .color(Theme.accent))
        }
    }
}

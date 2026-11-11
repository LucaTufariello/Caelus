//
//  ContentView.swift
//  SatTracker
//
//  Three columns: the catalog on the left, the globe in the middle, the selected
//  object on the right. The inspector appears only when something is selected,
//  so the globe gets the whole width for browsing.
//

import SwiftUI

struct ContentView: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()

            ZStack {
                // Transparent while a window capture is composited, so the
                // Metal scene shows through the chrome layer.
                Theme.globeBackdrop.opacity(model.isCapturingSnapshot ? 0 : 1)
                globe
                globeOverlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.selectedIndex != nil {
                SatelliteInspector()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Theme.background.opacity(model.isCapturingSnapshot ? 0 : 1))
        .animation(.easeInOut(duration: 0.18), value: model.selectedIndex != nil)
        .overlay {
            if model.loadState != .ready {
                LoadingOverlay()
            }
        }
    }

    // MARK: - Globe

    @ViewBuilder
    private var globe: some View {
        if let scene = model.globeScene {
            GlobeView(scene: scene,
                      buffer: model.buffer,
                      onSelect: { index in model.select(index) },
                      onHover: { index in model.hoveredIndex = index },
                      onFocusCoordinate: { lat, lon in
                          model.focusOnCoordinate(latitude: lat, longitude: lon)
                      },
                      onResetCamera: { model.resetCamera() },
                      onViewReady: { view in
                          model.globeView = view
                          model.captureSnapshotIfRequested()
                      })
        } else {
            Color.clear
        }
    }

    // MARK: - Overlays

    private var globeOverlay: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                hoverCard
                Spacer(minLength: 12)
                viewControls
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Spacer(minLength: 0)

            StatusBar()
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .allowsHitTesting(true)
    }

    /// A small readout that follows the pointer to whatever object is under it.
    @ViewBuilder
    private var hoverCard: some View {
        if let index = model.hoveredIndex,
           index != model.selectedIndex,
           let record = model.record(for: index) {
            HUDPanel(padding: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(record.renderGroup.color)
                        .frame(width: 5, height: 5)
                    Text(record.name)
                        .font(Theme.text(11, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(record.id)")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textTertiary)
                    if let altitude = model.altitudeKm(for: index) {
                        Text("\(Formatters.altitude(altitude)) km")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    private var viewControls: some View {
        HUDPanel(padding: 3) {
            HStack(spacing: 1) {
                IconButton(systemName: "circle.dashed",
                           help: "Orbit path (⌥⌘O)",
                           isActive: model.showOrbitPath) {
                    model.setShowOrbitPath(!model.showOrbitPath)
                }
                IconButton(systemName: "point.topleft.down.to.point.bottomright.curvepath",
                           help: "Ground track (⌥⌘G)",
                           isActive: model.showGroundTrack) {
                    model.setShowGroundTrack(!model.showGroundTrack)
                }
                IconButton(systemName: "antenna.radiowaves.left.and.right",
                           help: "Ground station",
                           isActive: model.showObserver) {
                    model.setShowObserver(!model.showObserver)
                }

                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1, height: 15)
                    .padding(.horizontal, 2)

                IconButton(systemName: "arrow.counterclockwise",
                           help: "Reset camera (⌘0)") {
                    model.resetCamera()
                }
            }
        }
    }
}

// MARK: - Loading

private struct LoadingOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Theme.background.opacity(0.82).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.accent)

                VStack(spacing: 5) {
                    Text("Acquiring catalog")
                        .font(Theme.text(14, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("CelesTrak GP elements · SGP4 propagation")
                        .font(Theme.text(11.5))
                        .foregroundStyle(Theme.textTertiary)
                }

                if case .failed(let message) = model.loadState {
                    Text(message)
                        .font(Theme.text(11.5))
                        .foregroundStyle(Theme.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)

                    Button("Retry") { model.refresh(force: true) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .controlSize(.small)
                }
            }
            .padding(30)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
    }
}

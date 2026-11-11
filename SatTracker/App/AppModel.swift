//
//  AppModel.swift
//  SatTracker
//
//  The application's single source of truth.
//
//  Owns the catalog, the propagation engine and the globe; runs the one-hertz
//  tick that pushes snapshots to the renderer; and persists the handful of
//  preferences a returning user expects to find unchanged.
//

import AppKit
import Observation
import SatelliteKit
import simd
import SwiftUI

@MainActor
@Observable
final class AppModel {

    // MARK: - Load state

    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    // MARK: - Catalog

    private(set) var catalog: SatelliteCatalog = .empty
    private(set) var loadState: LoadState = .idle
    private(set) var diagnostics = LoadDiagnostics()
    private(set) var provenance: DataProvenance = .none
    private(set) var groupMeta: [String: CacheMeta] = [:]
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var statusMessage: String?

    // MARK: - Selection

    private(set) var selectedIndex: Int?
    private(set) var selectedState: SatelliteState?
    private(set) var trackSamples: [TrackSample] = []
    private(set) var passes: [PassEvent] = []
    private(set) var isLoadingPasses = false
    var hoveredIndex: Int?

    // MARK: - Filters

    var query: String = ""
    private(set) var activeGroups: Set<SatelliteGroup> = Set(SatelliteGroup.allCases)
    var favoritesOnly: Bool = false

    // MARK: - Favourites

    private(set) var favorites: Set<Int> = []

    // MARK: - Settings

    var observer: ObserverSite = .rome
    private(set) var showOrbitPath = true
    private(set) var showGroundTrack = true
    private(set) var showObserver = true
    private(set) var pointSize: Double = 1.0

    // MARK: - Runtime telemetry

    private(set) var snapshotDuration: Double = 0
    private(set) var propagationFailures = 0
    private(set) var lastTick: Date?
    private(set) var frameRate: Double = 0
    private(set) var globeScene: GlobeScene?

    // MARK: - Collaborators

    @ObservationIgnored let buffer = SnapshotBuffer()
    @ObservationIgnored private let service = CatalogService()
    @ObservationIgnored private let engine = PropagationEngine()
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var trackTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastTrackUpdate = Date.distantPast
    @ObservationIgnored weak var globeView: GlobeSCNView?
    @ObservationIgnored private var didCaptureSnapshot = false

    /// While true the chrome renders without its opaque backdrop so a window
    /// capture can composite the Metal scene underneath it.
    var isCapturingSnapshot = false

    // MARK: - Search memo

    @ObservationIgnored private var searchCacheKey: SearchCacheKey?
    @ObservationIgnored private var searchCache: [Int] = []
    @ObservationIgnored private var favoritesVersion = 0

    private struct SearchCacheKey: Equatable {
        var query: String
        var groups: Set<SatelliteGroup>
        var favoritesOnly: Bool
        var favoritesVersion: Int
    }

    // MARK: - Lifecycle

    init() {
        StartupClock.mark("model created")
        loadPreferences()
        startFromCache()
    }

    // MARK: - Boot

    /// Show whatever is on disk immediately, then go to the network.
    private func startFromCache() {
        loadState = .loading
        let service = self.service
        Task.detached(priority: .userInitiated) {
            let cached = service.loadFromCache()
            await MainActor.run { [weak self] in
                guard let self else { return }
                StartupClock.mark("cache read (\(cached?.catalog.count ?? 0) objects)")
                if let cached {
                    self.apply(cached)
                }
                self.refresh(force: false)
            }
        }
    }

    func refresh(force: Bool) {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusMessage = nil

        let service = self.service
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let result = await service.refresh(force: force)
            guard let self, !Task.isCancelled else { return }
            self.isRefreshing = false
            self.apply(result)
        }
    }

    private func apply(_ result: CatalogService.LoadResult) {
        let isFirstLoad = catalog.count == 0
        catalog = result.catalog
        diagnostics = result.diagnostics
        provenance = result.provenance
        groupMeta = result.groupMeta
        lastRefresh = result.checkedAt
        statusMessage = result.isDegraded ? "Some sources were unavailable — showing cached data." : nil

        if result.catalog.count > 0 {
            loadState = .ready
        } else if isFirstLoad {
            loadState = .failed("No satellite data could be loaded. Check your connection and retry.")
        }

        guard result.catalog.count > 0 else { return }

        if isFirstLoad {
            StartupClock.mark("first catalog applied (\(result.catalog.count) objects)")
            buildGlobe()
            Task { await engine.load(result.catalog.records) }
            startTicking()
        } else {
            // Elements changed underneath us: rebuild the propagators but keep
            // the current selection if it still exists.
            Task {
                await engine.load(result.catalog.records)
                if let index = selectedIndex, index < result.catalog.count {
                    await refreshSelection(for: index, rebuildTrack: true)
                }
            }
        }

        invalidateSearch()
        if let index = selectedIndex, index >= result.catalog.count {
            select(nil)
        }
    }

    private func buildGlobe() {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let scene = GlobeScene(renderIndices: catalog.renderIndices, screenScale: scale)
        for group in SatelliteGroup.allCases {
            scene.setVisible(group, activeGroups.contains(group))
        }
        scene.setObserverVisible(showObserver)
        scene.observer.update(site: observer)
        scene.satellites.setPointRadius(CGFloat(2.2 * pointSize), screenScale: scale)
        globeScene = scene
    }

    // MARK: - Tick

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                next = next.advanced(by: .seconds(1))
                let now = clock.now
                if next <= now { next = now.advanced(by: .seconds(1)) }
                do {
                    try await clock.sleep(until: next)
                } catch {
                    return
                }
            }
        }
    }

    private func tick() async {
        let now = Date()
        let snapshot = await engine.tick(at: now)
        buffer.push(snapshot)
        StartupClock.markOnce("first tick",
                              "first tick (\(Int(snapshot.duration * 1000)) ms, \(snapshot.valid.filter { $0 }.count) valid)")

        lastTick = now
        snapshotDuration = snapshot.duration
        propagationFailures = snapshot.failures

        globeScene?.updateSun(SunCalculator.sceneDirection(at: now))

        guard let index = selectedIndex else { return }

        if let state = await engine.state(at: index, date: now, site: observer) {
            guard selectedIndex == index else { return }
            selectedState = state
            globeScene?.orbits.setMarker(position: state.position, color: color(for: index))
        }

        // The orbit path drifts slowly in the Earth-fixed frame; a refresh every
        // few seconds is indistinguishable from continuous.
        if now.timeIntervalSince(lastTrackUpdate) > 5 {
            lastTrackUpdate = now
            await refreshTrack(for: index)
        }
    }

    // MARK: - Selection

    func select(_ index: Int?, fly: Bool = false) {
        guard index != selectedIndex else {
            if fly, let index { flyTo(index) }
            return
        }
        selectedIndex = index
        selectedState = nil
        trackSamples = []
        passes = []
        globeScene?.orbits.clear()

        guard let index, catalog.records.indices.contains(index) else { return }
        Task { await refreshSelection(for: index, rebuildTrack: true) }
        if fly { flyTo(index) }
    }

    func select(id: Int, fly: Bool = false) {
        guard let index = catalog.index(id: id) else { return }
        select(index, fly: fly)
    }

    private func refreshSelection(for index: Int, rebuildTrack: Bool) async {
        let now = Date()
        if let state = await engine.state(at: index, date: now, site: observer) {
            guard selectedIndex == index else { return }
            selectedState = state
            globeScene?.orbits.setMarker(position: state.position, color: color(for: index))
        }
        if rebuildTrack {
            await refreshTrack(for: index)
        }
        await refreshPasses(for: index)
    }

    private func refreshTrack(for index: Int) async {
        guard selectedIndex == index, catalog.records.indices.contains(index) else { return }
        let record = catalog.records[index]
        let period = record.periodMinutes > 1 ? record.periodMinutes : 95
        let halfSpan = min(720, max(40, period / 2))
        let step = max(10, (2 * halfSpan * 60) / 260)

        let samples = await engine.trackSamples(at: index,
                                                date: Date(),
                                                halfSpanMinutes: halfSpan,
                                                stepSeconds: step)
        guard selectedIndex == index else { return }
        trackSamples = samples
        globeScene?.orbits.update(samples: samples,
                                  color: color(for: index),
                                  showOrbit: showOrbitPath,
                                  showGround: showGroundTrack)
    }

    private func refreshPasses(for index: Int) async {
        isLoadingPasses = true
        defer { isLoadingPasses = false }
        let site = observer
        let events = await engine.passes(at: index,
                                         site: site,
                                         from: Date(),
                                         hours: 24,
                                         minElevation: 10,
                                         limit: 8)
        guard selectedIndex == index else { return }
        passes = events
    }

    private func flyTo(_ index: Int) {
        guard let scene = globeScene, catalog.records.indices.contains(index) else { return }
        let record = catalog.records[index]
        let altitude = max(0, record.perigeeKm)
        let distance = Float(min(6, max(1.9, 1 + altitude / GeoMath.earthRadiusKm + 1.5)))
        if let state = selectedState {
            scene.focus(latitude: state.latitude, longitude: state.longitude, distance: distance)
        } else {
            Task {
                guard let state = await engine.state(at: index, date: Date(), site: observer) else { return }
                scene.focus(latitude: state.latitude, longitude: state.longitude, distance: distance)
            }
        }
    }

    // MARK: - Favourites

    func isFavorite(_ id: Int) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: Int) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        favoritesVersion += 1
        saveFavorites()
        invalidateSearch()
    }

    func toggleFavoriteSelection() {
        guard let index = selectedIndex, catalog.records.indices.contains(index) else { return }
        toggleFavorite(catalog.records[index].id)
    }

    var favoriteActionTitle: String {
        guard let record = selectedRecord else { return "Add to Favorites" }
        return favorites.contains(record.id) ? "Remove from Favorites" : "Add to Favorites"
    }

    // MARK: - Search focus

    /// Bumped by ⌘F; the sidebar watches it and focuses its field.
    private(set) var searchFocusToken = 0

    func requestSearchFocus() {
        searchFocusToken += 1
    }

    // MARK: - Filters

    var visibleCount: Int {
        guard !activeGroups.isEmpty else { return 0 }
        return catalog.renderIndices.reduce(0) { total, entry in
            activeGroups.contains(entry.key) ? total + entry.value.count : total
        }
    }

    func setGroup(_ group: SatelliteGroup, enabled: Bool) {
        if enabled { activeGroups.insert(group) } else { activeGroups.remove(group) }
        globeScene?.setVisible(group, enabled)
        invalidateSearch()
    }

    func setAllGroups(_ enabled: Bool) {
        activeGroups = enabled ? Set(SatelliteGroup.allCases) : []
        for group in SatelliteGroup.allCases {
            globeScene?.setVisible(group, enabled)
        }
        invalidateSearch()
    }

    func invalidateSearch() {
        searchCacheKey = nil
    }

    /// Ranked catalog indices for the current query and filters.
    ///
    /// Memoised on the filter inputs: SwiftUI may read this many times per
    /// frame, and the underlying scan touches every record.
    var searchResults: [Int] {
        let key = SearchCacheKey(query: query,
                                 groups: activeGroups,
                                 favoritesOnly: favoritesOnly,
                                 favoritesVersion: favoritesVersion)
        if key == searchCacheKey { return searchCache }
        searchCache = catalog.search(query,
                                     groups: activeGroups,
                                     favoritesOnly: favoritesOnly,
                                     favorites: favorites)
        searchCacheKey = key
        return searchCache
    }

    // MARK: - Settings

    func setShowOrbitPath(_ enabled: Bool) {
        showOrbitPath = enabled
        redrawTracks()
    }

    func setShowGroundTrack(_ enabled: Bool) {
        showGroundTrack = enabled
        redrawTracks()
    }

    func setShowObserver(_ enabled: Bool) {
        showObserver = enabled
        globeScene?.setObserverVisible(enabled)
    }

    func setPointSize(_ size: Double) {
        pointSize = size
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        globeScene?.satellites.setPointRadius(CGFloat(2.2 * size), screenScale: scale)
    }

    func setObserver(_ site: ObserverSite) {
        observer = site
        globeScene?.observer.update(site: site)
        saveObserver()
        if let index = selectedIndex {
            Task {
                await refreshSelection(for: index, rebuildTrack: false)
                await refreshPasses(for: index)
            }
        }
    }

    private func redrawTracks() {
        guard let index = selectedIndex, !trackSamples.isEmpty else { return }
        globeScene?.orbits.update(samples: trackSamples,
                                  color: color(for: index),
                                  showOrbit: showOrbitPath,
                                  showGround: showGroundTrack)
    }

    func resetCamera() {
        globeScene?.resetCamera()
    }

    func focusOnCoordinate(latitude: Double, longitude: Double) {
        globeScene?.focus(latitude: latitude, longitude: longitude, distance: 2.4)
    }

    // MARK: - Helpers

    func color(for index: Int) -> NSColor {
        guard catalog.records.indices.contains(index) else { return NSColor(Theme.textSecondary) }
        return NSColor(catalog.records[index].renderGroup.color)
    }

    func record(for index: Int) -> SatelliteRecord? {
        guard catalog.records.indices.contains(index) else { return nil }
        return catalog.records[index]
    }

    var selectedRecord: SatelliteRecord? {
        guard let index = selectedIndex else { return nil }
        return record(for: index)
    }

    /// Latest propagated position of a satellite, for the HUD and markers.
    func position(for index: Int) -> SIMD3<Float>? {
        let current = buffer.pair().current
        guard current.valid.indices.contains(index), current.valid[index] else { return nil }
        return current.positions[index]
    }

    /// Altitude in kilometres straight from the last snapshot.
    ///
    /// Reading `lastTick` here is deliberate: it registers the caller's view
    /// with observation, so a list row refreshes once a second without the
    /// parent having to re-evaluate the whole catalog.
    func altitudeKm(for index: Int) -> Double? {
        _ = lastTick
        guard let position = position(for: index) else { return nil }
        return (Double(simd_length(position)) - 1) * GeoMath.earthRadiusKm
    }

    // MARK: - Preferences

    private enum Key {
        static let favorites = "favorites"
        static let observer = "observer"
        static let showOrbit = "showOrbitPath"
        static let showGround = "showGroundTrack"
        static let showObserver = "showObserver"
        static let pointSize = "pointSize"
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard
        favorites = Set(defaults.array(forKey: Key.favorites) as? [Int] ?? [])

        if let data = defaults.data(forKey: Key.observer),
           let site = try? JSONDecoder().decode(ObserverSite.self, from: data) {
            observer = site
        }
        if defaults.object(forKey: Key.showOrbit) != nil {
            showOrbitPath = defaults.bool(forKey: Key.showOrbit)
        }
        if defaults.object(forKey: Key.showGround) != nil {
            showGroundTrack = defaults.bool(forKey: Key.showGround)
        }
        if defaults.object(forKey: Key.showObserver) != nil {
            showObserver = defaults.bool(forKey: Key.showObserver)
        }
        if defaults.object(forKey: Key.pointSize) != nil {
            pointSize = min(2.5, max(0.5, defaults.double(forKey: Key.pointSize)))
        }
    }

    private func saveFavorites() {
        UserDefaults.standard.set(Array(favorites), forKey: Key.favorites)
    }

    private func saveObserver() {
        if let data = try? JSONEncoder().encode(observer) {
            UserDefaults.standard.set(data, forKey: Key.observer)
        }
    }

    func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(showOrbitPath, forKey: Key.showOrbit)
        defaults.set(showGroundTrack, forKey: Key.showGround)
        defaults.set(showObserver, forKey: Key.showObserver)
        defaults.set(pointSize, forKey: Key.pointSize)
    }

    // MARK: - Snapshots

    /// Render the whole window to a PNG on disk.
    ///
    /// `cacheDisplay` captures the SwiftUI chrome but not the Metal-backed
    /// scene view, so the live globe snapshot is composited into its frame.
    @discardableResult
    func captureSnapshot(to url: URL) async -> Bool {
        guard let globe = globeView else { return false }
        isCapturingSnapshot = true
        try? await Task.sleep(for: .milliseconds(150))
        let data = Self.windowPNG(globe: globe)
        isCapturingSnapshot = false
        guard let data else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private static func windowPNG(globe: GlobeSCNView) -> Data? {
        // A paused or occluded view can hand back an empty drawable, so make sure
        // the renderer is live for the duration of the capture.
        let wasPlaying = globe.isPlaying
        globe.isPlaying = true
        globe.rendersContinuously = true
        let sceneImage = globe.snapshot()
        globe.isPlaying = wasPlaying

        if let debugPath = ProcessInfo.processInfo.environment["SATTRAKER_SNAPSHOT_SCENE"] {
            let data = sceneImage.tiffRepresentation.flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            }
            if let data { try? data.write(to: URL(fileURLWithPath: debugPath)) }
        }

        guard let window = globe.window,
              let contentView = window.contentView,
              let chromeRep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        else {
            return sceneImage.tiffRepresentation.flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            }
        }

        // Chrome only: the globe is hidden, so the capture is transparent where
        // the scene belongs.
        let wasHidden = globe.isHidden
        globe.isHidden = true
        contentView.cacheDisplay(in: contentView.bounds, to: chromeRep)
        globe.isHidden = wasHidden

        guard let chrome = chromeRep.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: chrome.width,
                                      height: chrome.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let full = CGRect(x: 0, y: 0, width: chrome.width, height: chrome.height)
        let scale = CGFloat(chrome.width) / max(1, contentView.bounds.width)

        // The globe's frame in the hosting view is flipped (origin top-left);
        // Core Graphics counts from the bottom, so mirror the y axis.
        let frame = globe.convert(globe.bounds, to: contentView)
        let sceneRect = CGRect(x: frame.minX * scale,
                               y: (contentView.bounds.height - frame.maxY) * scale,
                               width: frame.width * scale,
                               height: frame.height * scale)

        if let scene = sceneImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(scene, in: sceneRect)
        }
        // Chrome last: it is transparent over the globe, so the scene shows through.
        context.draw(chrome, in: full)

        guard let output = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: output)
        return rep.representation(using: .png, properties: [:])
    }

    func saveSnapshotWithPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "SatTracker.png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await captureSnapshot(to: url) }
    }

    /// Headless capture used by `Tools/snapshot.sh` and by the screenshot pass
    /// during development: `SATTRAKER_SNAPSHOT=/path/to.png make run`.
    func captureSnapshotIfRequested() {
        guard !didCaptureSnapshot,
              let path = ProcessInfo.processInfo.environment["SATTRAKER_SNAPSHOT"] else { return }
        didCaptureSnapshot = true

        if let pose = ProcessInfo.processInfo.environment["SATTRAKER_SNAPSHOT_POSE"] {
            let parts = pose.split(separator: ",").compactMap { Double($0) }
            if parts.count == 3 {
                globeScene?.focus(latitude: parts[0], longitude: parts[1], distance: Float(parts[2]))
            }
        }
        if ProcessInfo.processInfo.environment["SATTRAKER_SNAPSHOT_SELECT"] == "1",
           let index = searchResults.first {
            select(index)
        }

        Task {
            try? await Task.sleep(for: .seconds(2.5))
            _ = await captureSnapshot(to: URL(fileURLWithPath: path))
            try? await Task.sleep(for: .milliseconds(200))
            NSApp.terminate(nil)
        }
    }

    // MARK: - Maintenance

    func clearCache() {
        Task {
            try? await service.clearCache()
            statusMessage = "Cache cleared. Refresh to download fresh elements."
        }
    }

    var cacheBytes: Int { service.diskUsage() }
}

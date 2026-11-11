# SatTracker

A native macOS app that renders the live orbital catalog on a 3D Earth. Every
object in the CelesTrak GP catalog is propagated with SGP4 once a second and
drawn as a point on a rotating globe, with orbit paths, ground tracks, pass
predictions for your ground station, and a searchable browser for all of it.

SwiftUI for the interface, SceneKit for the globe. No web view, no Electron, no
Tauri — a single arm64 binary linked against SatelliteKit 2.1.2.

---

## Running it

```sh
make run      # generate the Xcode project, resolve packages, build, launch
make test     # unit tests, including the 16 000-object performance gate
make build    # build only
make clean    # remove build products
```

Requirements: macOS 14 or later on Apple silicon, Xcode 16 or later, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
`SatTracker.xcodeproj` is generated from `project.yml` and is not checked in.

The first launch needs a network connection to download the element sets; after
that the app starts from its cache and works offline.

### Build notes

SwiftPM's default cache lives in `~/Library/Caches`, which the build sandbox
cannot write to here, so the Makefile passes workspace-local package paths to
`xcodebuild`:

```
-derivedDataPath .build
-clonedSourcePackagesDirPath .build/SourcePackages
-packageCachePath .build/swiftpm-cache
```

Those three paths must be **absolute**. Given relative paths, `xcodebuild`
silently resolves nothing and the build fails with *"Missing package product
'SatelliteKit'"*.

---

## What it does

**Globe.** A unit-radius Earth with a day/night terminator driven by the real
subsolar point, an atmosphere shell, and a star field. Satellites are drawn as
screen-space points in six colour-coded groups: stations, Starlink, navigation,
weather, science, other. Positions are interpolated between the two most recent
one-hertz snapshots, so motion is smooth at 60 fps even though the propagator
runs once a second.

**Selection.** Click a point on the globe or a row in the list. The inspector
shows live altitude, velocity, sub-satellite point, range/elevation/azimuth from
your station, the orbital elements the propagator is actually using, and the
next passes. The globe draws the orbit path, the ground track (past dim, future
bright) and a pulsing marker on the object.

**Passes.** Predicted for the selected object over the next 24 hours above 10°
elevation, with rise/peak/set times, peak elevation, compass bearings, duration
and a flag for passes where the satellite is sunlit while the sky is dark.

**Search and filters.** Type a name or NORAD number (⌘F). Group chips filter
both the list and the globe. Favourites persist across launches and can be
isolated with the star toggle.

**Ground station.** Six presets plus free coordinates, applied to the observer
marker, the horizon circle, the range/elevation readout and pass predictions.

---

## Data

### Sources

| Source | Endpoint | Role |
| --- | --- | --- |
| CelesTrak GP | `https://celestrak.org/NORAD/elements/gp.php?GROUP=<group>&FORMAT=tle` | Primary |
| SatNOGS | `https://db.satnogs.org/api/tle/` | Fallback when the base catalog is unavailable |

Groups fetched: `active` (the base catalog, ~15 900 objects), plus `stations`,
`gps-ops`, `weather` and `science` for tagging. Starlink is tagged by the
`STARLINK` name prefix inside `active`; the dedicated `starlink` group is only
requested if that yields fewer than 5 000 objects.

Requests carry `User-Agent: SatTracker/0.1 (macOS; personal use)`.

### The two-hour window

CelesTrak regenerates GP data every two hours and rate-limits per client. Ask
again inside the window and it answers **HTTP 403** with

> GP data has not updated since your last successful download of GROUP=active at
> … Data is updated once every 2 hours.

That is not an error. The app treats it as `.unchanged`: the cached text is kept,
`lastChecked` moves forward, and nothing is re-requested for another 30 minutes.
A group is only fetched when its cache entry is older than the recheck interval,
or when you press ⌘R.

Each group's text and metadata are cached under
`~/Library/Containers/com.lucatufariello.SatTracker/Data/Library/Application Support/SatTracker/`:

```
tle/active.tle    tle/stations.tle    tle/starlink.tle    …
meta.json
```

SatNOGS results are cached the same way, so an offline relaunch still has a
catalog.

### Parsing

Three-line elements are validated before they reach the propagator: line length,
record type, NORAD agreement between lines 1 and 2, the modulo-10 checksum over
columns 0–67, every field SatelliteKit force-unwraps, and physical range checks
on inclination, eccentricity and mean motion. Alpha-5 catalog numbers are
supported. Rejected lines are counted and surfaced in Settings → Diagnostics
rather than silently dropped.

---

## Frame calibration

The scene is Earth-fixed. `GeoMath.unitVector(lat:lon:)` maps:

| Geodetic | Scene vector |
| --- | --- |
| 0°N 0°E (Gulf of Guinea) | `( 1,  0,  0)` |
| 90°N (north pole) | `( 0,  1,  0)` |
| 0°N 90°E (Indian Ocean) | `( 0,  0, −1)` |

So **y is the polar axis** and longitude increases clockwise when viewed from
the north pole. `GeoMath.longitudeOffset` is therefore **0**.

The spec suggested calibrating a rotation offset against `SCNSphere`'s UV
layout. Instead `EarthNode` builds its own UV sphere from the same convention,
which makes the mapping exact by construction rather than by measurement — there
is no offset to calibrate, and the constant is kept as documentation of that
decision. `GeoMathTests` asserts all three axis cases plus a round-trip over a
latitude/longitude grid.

One detail is not derivable from the frame convention: SceneKit samples an
`NSImage`-backed texture with **v = 0 at the top row**, while an equirectangular
map has its north pole in that row. The sphere therefore stores
`v = 1 − (lat + 90)/180`. Without the inversion the geometry is still correct —
satellites stay where the maths puts them — but the continents render mirrored
across the equator, so 30°S shows Greenland. `EarthNodeTests` asserts the
convention and then samples the shipped texture at known places (the USA is
land, the South Pacific is water) so the two cannot drift apart again.

---

## Performance

Budgets from the spec, and what the current Release build measures on an
Apple-silicon machine. The live figures are from a real catalog of 10 784
objects (the `starlink` group plus the tagging groups); the stress figures are
from a 16 000-object synthetic catalog.

| Metric | Budget | Measured |
| --- | --- | --- |
| 16 000 objects propagated per tick | < 250 ms | **4.3–5.0 ms** (`PropagationTests`), 5 ms live |
| Cold start, cached | < 2 s | **0.29 s** to first tick with 10 784 objects |
| Cold start, network | < 8 s | dominated by the download |
| Steady-state CPU | < 15 % | **4.0–5.5 %** live; 8.5–12.6 % at 16 000 |
| Camera | 60 fps | 60 fps while the camera moves, 30 fps once it settles |
| Memory | < 250 MB | **226 MB** live; 219 MB at 16 000 |

The startup figures come from `SATTRAKER_STARTUP_LOG=1` (see *Development
hooks*); memory is `vmmap -summary`'s physical footprint, not RSS.

`PropagationTests.testPerformance` enforces the first row: it builds a 16 000
object catalog, warms the propagators, and fails if the median tick exceeds
250 ms.

The renderer stops when the window is occluded (`GlobeSCNView` watches
`NSWindow.didChangeOcclusionStateNotification` and toggles `isPlaying` and
`rendersContinuously`), so a backgrounded app costs nothing.

Two things keep the idle cost down:

- **Adaptive frame rate.** The globe runs at 60 fps while the camera is easing
  and drops to 30 fps once it settles. Satellites move well under a pixel per
  second, so the lower rate is invisible; dragging stays at the full rate.
- **Texture budget.** The day map is 4096 × 2048, but the night, normal and
  specular maps are 2048 × 1024 and 1024 × 512. At full resolution those three
  alone cost about 50 MB of decoded image memory for detail the terminator
  blend hides.

How the speed is achieved:

- `Satellite` propagators are built once per catalog load, not per tick.
- Each tick splits the catalog into `cores × 3` chunks and propagates them in a
  `withTaskGroup`.
- Positions are written into a pre-allocated `MTLBuffer` and handed to SceneKit
  through `SCNGeometrySource(buffer:…)`. Nothing is allocated per frame and no
  geometry is rebuilt.
- The render thread interpolates between the two most recent snapshots using an
  `OSAllocatedUnfairLock` hand-off, so the main actor is never on the critical
  path of a frame.

---

## Architecture

```
SatTracker/
  App/           SatTrackerApp, AppModel (the single source of truth), Commands
  Data/          CelesTrak client, SatNOGS fallback, cache, TLE parser, catalog
  Propagation/   SGP4 engine, pass predictor, solar geometry, frame maths
  Scene/         GlobeScene, EarthNode, SatelliteLayer, OrbitTrackLayer, observer
  UI/            ContentView, SidebarView, SatelliteInspector, PassesView, Settings
```

- **`AppModel`** is an `@Observable` main-actor object. It owns the catalog, the
  selection, the tick loop and the preferences, and is the only thing the views
  talk to.
- **`PropagationEngine`** is an actor. It owns the propagators and produces
  immutable `SatelliteSnapshot` values.
- **`SnapshotBuffer`** is the lock-protected bridge to the render thread.
- **`GlobeScene`** and everything under `Scene/` is `@MainActor`; the only code
  that runs off the main thread is the propagation task group and SceneKit's own
  render callback, which touches nothing but the buffer and the camera rig.
- **`CameraRig`** keeps its target and current pose in an
  `OSAllocatedUnfairLock`. Input writes the target; the render thread eases
  toward it. Drag feel is therefore independent of frame rate.

---

## Deviations from the spec

1. **`longitudeOffset = 0`, with a self-built UV sphere** rather than a
   calibrated offset on `SCNSphere`. See *Frame calibration* above.
2. **Absolute package paths in the Makefile.** Required for SwiftPM to resolve
   at all in this environment; see *Build notes*.
3. **SatNOGS is cached.** The spec did not say to persist the fallback, but
   without it an offline relaunch after a fallback load would show an empty
   globe. Its request timeout is raised to 120 s because the endpoint regularly
   takes over a minute.
4. **Pass predictions are computed for the selected object only**, not
   precomputed for every favourite. Scanning 16 000 objects for passes on every
   selection change would blow the latency budget; the selected-object scan
   completes in well under a second.
5. **The globe pauses when occluded.** Not required, but it is the cheapest way
   to meet the CPU budget.

---

## Development hooks

Four environment variables exist for measurement and screenshots. None of them
change behaviour unless set.

| Variable | Effect |
| --- | --- |
| `SATTRAKER_SYNTHETIC_CATALOG=<n>` | Loads *n* generated satellites instead of contacting any source. |
| `SATTRAKER_STARTUP_LOG=1` | Prints one `[startup]` line per boot phase to stderr. |
| `SATTRAKER_SNAPSHOT=<path>` | Renders the window to a PNG after the first tick, then quits. |
| `SATTRAKER_SNAPSHOT_POSE=lat,lon,distance` | Camera pose for that capture. |
| `SATTRAKER_SNAPSHOT_SELECT=1` | Selects the first search result before capturing. |
| `SATTRAKER_SNAPSHOT_SCENE=<path>` | Also dumps the raw Metal scene, without the UI chrome. |

**Synthetic mode is QA only.** It exists because the real catalog depends on
CelesTrak's two-hour window, which makes the 16 000-object render path
impossible to exercise on demand. The generated elements are not real
satellites, so every surface that reports where the catalog came from — status
bar, sidebar indicator, Settings — shows **SYNTHETIC** in the danger colour
while the mode is on. `SyntheticCatalogTests` checks that the generated TLEs are
as well-formed as downloaded ones.

The sandbox only permits writes inside the app container, so snapshot paths must
live under
`~/Library/Containers/com.lucatufariello.SatTracker/Data/`.

---

## Attribution

- Earth surface textures: [Solar System Scope](https://www.solarsystemscope.com/textures/),
  CC BY 4.0.
- Orbital propagation: [SatelliteKit](https://github.com/gavineadie/SatelliteKit) 2.1.2 (MIT).
- Element sets: [CelesTrak](https://celestrak.org) (Dr T. S. Kelso).
  [SatNOGS](https://satnogs.org) as fallback.

---

## Acceptance checklist

| Requirement | Status |
| --- | --- |
| `make run` opens the app | ✅ |
| Globe shows ≥ 10 000 satellites | ✅ 10 784 real objects |
| Positions update at ≥ 1 Hz | ✅ 1 Hz tick, interpolated to 60 fps |
| Clicking shows details, orbit path, ground track | ✅ |
| Searching "ISS" and flying to it | ✅ |
| Passes for Rome match n2yo within ~1 min | ✅ ±30 s on rise/peak/set |
| Favourites persist | ✅ `UserDefaults` |
| Relaunch offline works from cache | ✅ |
| `make test` passes | ✅ 91 tests |
| No Electron, Tauri or web view | ✅ |

> **Note on catalog size.** During development CelesTrak's per-client two-hour
> window was closed for `GROUP=active`, so the base catalog could not be
> downloaded. The `starlink` group was available and yields 10 619 objects on
> its own, which together with `stations`, `gps-ops`, `weather` and `science`
> gives the 10 784-object catalog the figures above were measured against. When
> `GROUP=active` succeeds, the app replaces this with the full ~15 900-object
> catalog; the 16 000-object render and propagation path is exercised by
> `SATTRAKER_SYNTHETIC_CATALOG=16000` and by `PropagationTests.testPerformance`.

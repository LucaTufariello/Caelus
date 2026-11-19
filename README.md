# Caelus

A native macOS app that renders the live orbital catalog on a 3D Earth. Every
object in the CelesTrak GP catalog is propagated with SGP4 once a second and
drawn as a point on a rotating globe, with orbit paths, ground tracks, pass
predictions for your ground station, and a searchable browser for all of it.

A portable C++20 core, an AppKit/Objective-C++ shell and a Metal renderer.
No Xcode project, no Swift, no third-party packages — a single arm64 binary
built by a Makefile.

---

## Running it

```sh
make app      # build build/Caelus.app
make run      # build and open it
make launch   # run the binary in place, so CAELUS_* environment variables apply
make test     # build and run the C++ test suite
make clean    # remove build products
```

Requirements: macOS 14 or later on Apple silicon and the Xcode command line
tools (clang, `sips`, `iconutil`). Nothing else.

The first launch needs a network connection to download the element sets; after
that the app starts from its cache and works offline.

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

Requests carry `User-Agent: Caelus/0.1 (macOS; personal use)`.

### The two-hour window

CelesTrak regenerates GP data every two hours and rate-limits per client. Ask
again inside the window and it answers **HTTP 403** with

> GP data has not updated since your last successful download of GROUP=active at
> … Data is updated once every 2 hours.

That is not an error. The app treats it as `unchanged`: the cached text is kept,
`lastChecked` moves forward, and nothing is re-requested for another 30 minutes.
A group is only fetched when its cache entry is older than the recheck interval,
or when you press ⌘R.

Each group's text and metadata are cached under
`~/Library/Application Support/Caelus/`:

```
tle/active.tle    tle/stations.tle    tle/starlink.tle    …
meta.json
```

SatNOGS results are cached the same way, so an offline relaunch still has a
catalog.

### Parsing

Three-line elements are validated before they reach the propagator: line length,
record type, NORAD agreement between lines 1 and 2, the modulo-10 checksum over
columns 0–67, every field the propagator requires, and physical range checks on
inclination, eccentricity and mean motion. Alpha-5 catalog numbers are
supported. Rejected lines are counted and surfaced in Settings → Diagnostics
rather than silently dropped.

---

## Frame calibration

The scene is Earth-fixed. `caelus::GeoMath::unitVector(lat, lon)` maps:

| Geodetic | Scene vector |
| --- | --- |
| 0°N 0°E (Gulf of Guinea) | `( 1,  0,  0)` |
| 90°N (north pole) | `( 0,  1,  0)` |
| 0°N 90°E (Indian Ocean) | `( 0,  0, −1)` |

So **y is the polar axis** and longitude increases clockwise when viewed from
the north pole. `longitudeOffset` is therefore **0**.

`GlobeView` builds its own UV sphere from the same convention, which makes the
mapping exact by construction rather than by measurement. The sphere stores
`v = 1 − (lat + 90)/180` so that texture row 0 is the north pole; without the
inversion the geometry is still correct — satellites stay where the maths puts
them — but the continents render mirrored across the equator, so 30°S shows
Greenland. `GeoMathTests` asserts the axis cases plus a round-trip over a
latitude/longitude grid.

---

## Performance

Budgets from the spec, and what the current build measures on an Apple-silicon
machine.

| Metric | Budget | Measured |
| --- | --- | --- |
| 16 000 objects propagated per tick | < 250 ms | **1.2–1.7 ms** (`PropagationTests`; the app reports the same in its status bar) |
| Cold start, synthetic 16 000 | < 2 s | **0.27 s** to first catalog applied (`CAELUS_STARTUP_LOG=1`) |
| Cold start, network | < 8 s | dominated by the download |
| Camera | 60 fps | 60 fps while the camera moves, 30 fps once it settles |
| Memory | < 250 MB | dominated by the 4096 × 2048 day texture and vertex buffers |

`PropagationTests` enforces the first row: it builds a 16 000-object catalog,
warms the propagators, and fails if the median tick exceeds 250 ms.

How the speed is achieved:

- `sky::Satellite` propagators are built once per catalog load, not per tick.
- Each tick splits the catalog into `cores × 3` chunks and propagates them on
  `std::thread`s.
- Positions are written into a pre-allocated `MTLBuffer` and handed to Metal
  directly. Nothing is allocated per frame and no geometry is rebuilt.
- The render thread interpolates between the two most recent snapshots using a
  mutex-protected hand-off, so the main thread is never on the critical path of
  a frame.
- The render view drops to 30 fps once the camera settles.

---

## Architecture

```
Caelus/
  Core/            portable C++20 — no Apple frameworks
    Data/          CelesTrak client, SatNOGS fallback, cache, TLE parser,
                   catalog, synthetic catalog
    Geo/           frame maths, geodesy
    Net/           HttpClient interface
    Propagation/   engine, pass predictor, solar geometry
    Sky/           SGP4/SDP4 propagator, satellite, time
    Support/       filesystem, JSON
  App/             AppController (model + AppKit UI), main
  Render/          GlobeView (Metal), Shaders.h
  Net/             URLSession transport
  Resources/       Info.plist, textures, app icon
CaelusTests/Core/  C++ test runner and tests
```

- **`AppController`** owns the catalog, selection, tick loop and preferences,
  and is the only thing the views talk to.
- **`PropagationEngine`** owns the propagators and produces immutable
  `SatelliteSnapshot` values on a serial work queue.
- **`SnapshotBuffer`** is the lock-protected bridge to the render thread.
- **`CaelusGlobeView`** is an `MTKView` subclass; it compiles its shaders at
  launch, keeps the camera rig behind a mutex, and eases the camera toward the
  target on the render thread. Drag feel is therefore independent of frame rate.
- **UI** is AppKit: a sidebar with search, group chips, favourites and the
  table; an inspector built from stack views; a status bar; and a menu bar with
  the same shortcuts as the Swift version.

---

## Development hooks

Seven environment variables exist for measurement and screenshots. None of them
change behaviour unless set. Use `make launch` (not `make run`) so they reach
the process.

| Variable | Effect |
| --- | --- |
| `CAELUS_SYNTHETIC_CATALOG=<n>` | Loads *n* generated satellites instead of contacting any source. |
| `CAELUS_STARTUP_LOG=1` | Prints one `Caelus startup:` line per boot phase to stderr. |
| `CAELUS_SNAPSHOT=<path>` | Renders the window to a PNG after the catalog loads, then quits. |
| `CAELUS_SNAPSHOT_POSE=lat,lon,distance` | Camera pose for that capture. |
| `CAELUS_SNAPSHOT_QUERY=<text>` | Types *text* into the search field before capturing. |
| `CAELUS_SNAPSHOT_SELECT=1` | Selects the first search result, flying the camera to it. |
| `CAELUS_SNAPSHOT_SCENE=<path>` | Also dumps the raw Metal scene, without the UI chrome. |

**Synthetic mode is QA only.** It exists because the real catalog depends on
CelesTrak's two-hour window, which makes the 16 000-object render path
impossible to exercise on demand. The generated elements are not real
satellites, so every surface that reports where the catalog came from — status
bar, sidebar indicator, Settings — shows **SYNTHETIC** in the danger colour
while the mode is on. `SyntheticCatalogTests` checks that the generated TLEs are
as well-formed as downloaded ones.

---

## Tests

`make test` builds `build/caelus-tests` from `CaelusTests/Core` and runs it:

```
PASS  118 passed, 0 failed (118 tests)
```

The suite covers the TLE parser and its rejection paths, the catalog and its
group tagging, the on-disk cache, the HTTP client's error and back-off ladder,
the SGP4/SDP4 propagator and its frame maths, pass prediction, solar geometry,
synthetic catalog generation, and the 16 000-object performance gate.

---

## Attribution

- Earth surface textures: [Solar System Scope](https://www.solarsystemscope.com/textures/),
  CC BY 4.0.
- Orbital propagation: SGP4/SDP4, ported to C++ from
  [SatelliteKit](https://github.com/gavineadie/SatelliteKit) 2.1.2 (MIT).
- Element sets: [CelesTrak](https://celestrak.org) (Dr T. S. Kelso).
  [SatNOGS](https://satnogs.org) as fallback.

---

## Acceptance checklist

| Requirement | Status |
| --- | --- |
| `make run` opens the app | ✅ |
| Globe shows ≥ 10 000 satellites | ✅ 16 000-object synthetic path; live catalog from cache |
| Positions update at ≥ 1 Hz | ✅ 1 Hz tick, interpolated to 60 fps |
| Clicking shows details, orbit path, ground track | ✅ |
| Searching "ISS" and flying to it | ✅ |
| Passes for Rome match n2yo within ~1 min | ✅ ±30 s on rise/peak/set |
| Favourites persist | ✅ `NSUserDefaults` |
| Relaunch offline works from cache | ✅ |
| `make test` passes | ✅ 118 tests |
| No Electron, Tauri or web view | ✅ |

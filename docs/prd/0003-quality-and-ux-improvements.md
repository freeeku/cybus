# PRD 0003 — Quality, performance & UX improvements (non-security)

> Status: ready-for-agent. Companion to [PRD-0002](./0002-security-hardening.md) (security hardening) — this PRD covers everything the 2026-07-04 review found that is *not* a security posture gap: correctness bugs, performance, UX stories from [PRD-0001](./0001-mvp.md) not fully met, code health, and shipping/testing gaps. Vocabulary follows [CONTEXT.md](../../CONTEXT.md).

## Correction to PRD-0002 (recorded here for the implementer)

PRD-0002 §1 says "deploy the existing Worker." Project history (2026-06-24) records that **CyNAP 403s requests from Cloudflare IPs**, which is why the app was pointed directly at the upstream in the first place — the Worker is currently dead code. Restoring an HTTPS realtime path therefore requires a host the upstream doesn't block: a small VPS or Fly.io/Render instance in an allowed region running the same thin caching proxy (same contract: `/gtfs-rt`, `/health`, 60 s snapshot cache, size caps). Evaluate free tiers per ADR-0001's free-tier-first constraint; keep the Worker code as the reference implementation of the contract. This is also **S4** below — the #1 App Store ship blocker (ATS exception to a bare IP is a likely rejection).

## Findings

| ID | Area | Finding | Where |
|----|------|---------|-------|
| C1 | Correctness | ~~`Dictionary(uniqueKeysWithValues:)` traps on duplicate trip IDs in a feed documented to repeat entities~~ **Fixed 2026-07-04** | `ios/Cybus/Domain/ArrivalBuilder.swift` |
| C2 | Correctness | Scheduled arrivals computed with `Calendar.current` (device timezone) instead of Europe/Nicosia | `ios/Cybus/Domain/GTFSStore.swift` (`upcomingTrips`, `activeServiceIds`) |
| C3 | Correctness | Bare-ID suffix uniqueness across providers is assumed, never validated | `pipeline/build_gtfs.py`, `GTFSStore.swift` |
| P1 | Performance | All SQLite work (incl. full-table `warmCaches` at launch) runs on the main actor | `AppModel.swift`, `GTFSStore.swift` |
| P2 | Performance | 102 MB first-launch download: no progress, no resume, full in-memory decompress | `AppModel.swift` (`StaticDataManager`) |
| P3 | Performance | `DateFormatter` allocated per rendered row; hardcoded `HH:mm` ignores locale | `ArrivalBuilder.swift` (`clockFormatted`) |
| P4 | Performance | Full trips/routes tables cached in dictionaries; footprint never measured against the 7-provider dataset | `GTFSStore.swift` (`warmCaches`) |
| U1 | UX | Feed errors swallowed silently — outage indistinguishable from "no buses" (PRD-0001 story 23) | `AppModel.swift` (`fetchAndApplyFeed`) |
| U2 | UX | No stop/route search | app-wide |
| U3 | UX | Location denial is silent; no path to Settings | `CybusMapView.swift`, `LocationProvider.swift` |
| U4 | UX | No localization (hardcoded English strings; Greek/Turkish market) | app-wide |
| U5 | UX | 16 pt stop tap targets (< 44 pt HIG minimum); no VoiceOver labels on markers | `CybusMapView.swift` |
| S1 | Code health | GRDB declared as SPM dependency but unused (raw sqlite3 API in use) | `ios/project.yml` |
| S2 | Shipping | No app icon / asset catalog — App Store blocker | `ios/` |
| S3 | Code health | `bareId`/`agency` GTFS-ID helpers duplicated | `GTFSStore.swift`, `ArrivalBuilder.swift` |
| S4 | Shipping | Realtime endpoint hosting unresolved (see correction above) | `AppConfig.swift`, `proxy/` |
| T1 | Testing | No tests for `GTFSStore` (already broke once — WAL bug), `StaticDataManager`, `AppModel` | `ios/CybusTests/` |
| T2 | Testing | No CI for iOS build/tests or proxy tests; only the nightly data publish runs | `.github/workflows/` |

## User Stories

1. As a rider, I want live and scheduled times to be correct regardless of my phone's timezone setting, so that I can trust the board. *(C2)*
2. As a rider, I want the map to stay smooth while the app loads and queries data, so that panning never stutters or hangs at launch. *(P1, P4)*
3. As a first-time rider on cellular, I want to see download progress and have the download survive interruption, so that the big first fetch isn't a black box. *(P2)*
4. As a rider during a feed outage, I want the app to tell me live data is unavailable and how old what I'm seeing is, so that an empty map reads as "no service/outage", not "broken app". *(U1)*
5. As a rider, I want to search for a stop or route by name/number, so that I don't have to hunt by panning. *(U2)*
6. As a rider who denied location, I want a gentle pointer to Settings when I tap "locate me", so that the button doesn't appear dead. *(U3)*
7. As a Greek- or Turkish-speaking rider, I want the app's own labels in my language and times in my locale's format, so that the app feels native. *(U4, P3)*
8. As a rider using VoiceOver or with motor impairments, I want labelled, adequately-sized tap targets on the map, so that I can use the app at all. *(U5)*
9. As the maintainer, I want the realtime endpoint on an HTTPS host the upstream accepts, so that the app can pass App Store review. *(S4)*
10. As the maintainer, I want every push to run the iOS, pipeline, and proxy test suites, so that regressions are caught before merge. *(T1, T2)*
11. As the maintainer, I want the ID-join assumptions validated at build time, so that a provider feed change can't silently mis-join routes. *(C3)*

## Implementation Decisions

### Correctness

- **C1 — done (2026-07-04):** `vehicleByTrip` now built with `Dictionary(_:uniquingKeysWith:)` keeping the first entry, matching the first-wins dedup used elsewhere in the builder.
- **C2:** introduce a single `gtfsCalendar` (`Calendar` with `TimeZone(identifier: "Europe/Nicosia")`) used by `upcomingTrips`/`activeServiceIds`. Source of truth: hardcode is acceptable (single-country app per CONTEXT.md); optionally read `agency_timezone` from agency.txt in the pipeline later.
- **C3:** pipeline computes bare-ID collision counts across providers for route/trip/stop IDs after merge; any collision fails the build with a clear message (feeds a PRD-0002 §4 publish gate). App keeps its current fallback behaviour.

### Performance

- **P1:** wrap `GTFSStore` in a dedicated actor (or use a serial `DispatchQueue`-backed wrapper) owned by `AppModel`; `updateVisibleStops` and store init become `async`. Map camera callbacks debounce and hop off the main actor for the query, publishing results back.
- **P2:** switch to `URLSession.downloadTask` with a delegate reporting progress to a visible progress bar; enable resumable downloads (`downloadTask(withResumeData:)`); stream-decompress to a temp file instead of full in-memory inflate (shared work with PRD-0002 §2's caps — implement once).
- **P3:** one cached `Date.FormatStyle`/`DateFormatter` (locale-aware time style, not hardcoded `HH:mm`).
- **P4:** measure `warmCaches` real footprint on the production dataset; if > ~50 MB, replace trips/headsign dictionaries with prepared-statement lookups + small LRU. Measure first — don't rebuild blind.

### UX

- **U1:** `AppModel` gains `feedStatus` (`live(asOf: Date)` / `stale(since: Date)` / `unavailable`); a small map-overlay chip renders it. Errors in `fetchAndApplyFeed` update status instead of vanishing into `try?`.
- **U2:** search screen over the static SQLite (stops by name, routes by short name), FTS5 table added by the pipeline or plain `LIKE` with the existing indexes — decide by measured latency; tapping a result centers the map / opens the stop sheet.
- **U3:** when authorization is `.denied`/`.restricted` and the user taps locate, show an alert with a "Open Settings" button (`UIApplication.openSettingsURLString`).
- **U4:** move user-facing strings to a String Catalog; localize Greek (el) first, Turkish (tr) second. Data-provided names stay as-is per PRD-0001 story 28.
- **U5:** wrap stop pins in a ≥ 44 pt contentShape hit area (visual size unchanged); add `accessibilityLabel` to vehicle ("Route 30 bus") and stop (stop name) annotations.

### Code health & shipping

- **S1:** remove GRDB from `project.yml` (staying on the raw sqlite3 API — it works, is tested in production, and GRDB migration buys nothing today).
- **S2:** add asset catalog + app icon (a generator script already exists at `ios/tools/make_app_icon.swift` — wire it up or commit its output).
- **S3:** single `GTFSID` enum (`bareId`, `agency`) in Domain; both call sites migrate.
- **S4:** decide + deploy the HTTPS realtime host (see correction above). Acceptance is PRD-0002 AC 1; the *host decision* lives here because the constraint is upstream IP-blocking, not security.

### Testing & CI

- **T1:** `GTFSStoreTests` against a small fixture SQLite (open path incl. WAL-header regression case, `upcomingTrips` across midnight + timezone, suffix fallback); `StaticDataManagerTests` for manifest/decompress/hash paths (URLProtocol stubs); `AppModel` feed-status transitions.
- **T2:** CI workflow on push/PR: `xcodebuild test` (iOS sim), `pytest pipeline/tests`, `npm test` in proxy. Pin runners/actions per PRD-0002 §5.

## Out of scope

- Android / cross-platform (ADR-0002).
- Favourites, accounts, notifications — new product surface, not "improvements".
- Route planning / directions.
- Vehicle-glide polish beyond what's shipped (tracked separately; verification was in progress as of 2026-07-01).

## Acceptance Criteria

1. Duplicate VehiclePosition entities for one trip in a fixture feed produce no crash and one vehicle row (unit test). *(C1 — test to be added with T1 wave)*
2. With device timezone set to e.g. `America/New_York`, scheduled arrivals for a fixture stop match Cyprus wall-clock expectations (unit test).
3. Pipeline fails with a named collision when two providers share a bare ID (pipeline test).
4. Launch with a warm 100 MB-class DB shows no main-thread hang > 100 ms attributable to store init (Instruments/os_signpost check); map pans smoothly during a stops query.
5. First launch shows determinate download progress; killing and relaunching mid-download resumes rather than restarts.
6. Airplane-mode with a cached DB: map loads stops, chip shows "live data unavailable"; restoring network flips it to "live" without relaunch.
7. Searching "30" finds route 30; searching a stop name centers the map on it.
8. Locate-tap with denied permission shows the Settings alert.
9. App runs fully in Greek when device language is Greek; times honour the locale's 12/24-hour setting.
10. VoiceOver reads route and stop names on map markers; stop pins hit-test at ≥ 44 pt.
11. GRDB absent from resolved packages; build still green.
12. App archive contains a valid icon set.
13. CI: a PR breaking any of the three test suites cannot merge green.

## Sequencing

1. **Wave 1 — correctness + ship blockers:** C2, C3, S4 (host decision unblocks PRD-0002 Wave 1), S2, T2 (CI first so later waves land tested).
2. **Wave 2 — performance:** P1, P2 (jointly with PRD-0002 §2), P3, P4 measurement.
3. **Wave 3 — UX:** U1–U5, T1, S1, S3.

# Data sources (verified 2026-06-18)

Source: Cyprus National Access Point (CyNAP), `traffic4cyprus.org.cy`. License: **Creative Commons Attribution 4.0**. No API key or login required.

## Real-time (GTFS-realtime) — CONFIRMED WORKING

- **Endpoint:** `http://20.19.98.194:8328/Api/api/gtfs-realtime`
- Single **combined** FeedMessage (protobuf, `gtfs_realtime_version "2.0"`). No sub-paths — `/vehiclepositions`, `/tripupdates`, etc. all return HTTP 500. TripUpdates and VehiclePositions arrive bundled in the one response.
- Plain unauthenticated `GET` → HTTP 200, `application/octet-stream`. Verified: returned a valid protobuf with TripUpdate entities.
- **Official update cadence: "up to 1 minute"** (per CyNAP metadata) — NOT the ~10s some clones claim. See caveat below.
- Note: served over plain **HTTP** (not HTTPS) on an IP:port. The proxy must fetch it server-side; iOS ATS would block this directly anyway.

## Static (GTFS) — CONFIRMED WORKING

- Open-data page: `https://motionbuscard.org.cy/opendata` (CyNAP dataset: `/dataset/publictransportstatic`)
- **One zip per provider** (7 total), hosted on `motionbuscard.org.cy`:
  | Provider | File |
  |---|---|
  | EMEL (Limassol) | `GTFS\6_google_transit.zip` |
  | OSYPA (Pafos) | `GTFS\2_google_transit.zip` |
  | OSEA (Famagusta) | `GTFS\4_google_transit.zip` |
  | Intercity | `GTFS\5_google_transit.zip` |
  | NPT (Nicosia) | `GTFS\9_google_transit.zip` |
  | LPT (Larnaca) | `GTFS\10_google_transit.zip` |
  | Pame Express | `GTFS\11_google_transit.zip` |
- **URL pattern (note the required `&rel=True`):**
  `https://motionbuscard.org.cy/opendata/downloadfile?file=GTFS%5C<n>_google_transit.zip&rel=True`
- **`&rel=True` is mandatory.** Without it the handler errors and 302-redirects to a "page not found" page (this was the earlier "open issue" — it was a missing param, not a browser/geo restriction). The `%5C` is an encoded backslash (Windows path separator) and is correct as-is.
- Verified (EMEL/Limassol, file 6): `HTTP 200`, `application/x-zip-compressed`, ~2.4 MB, valid zip (`PK`), full GTFS set incl. `shapes.txt`; 244 routes, 1,407 stops. No login/key required.
- Extra resources on the same page: `Topology\routes\routes.zip`, `Topology\stops\stops.csv`, and `Static\OpenDataDictionary.pdf` (field documentation).

## Open caveats to verify during build

1. **Static GTFS download** — RESOLVED: works with the `&rel=True` param (see above).
2. **`trip_id` ↔ vehicle correlation** for tap-to-track (some feeds omit vehicle info on TripUpdates).
3. **Realtime cadence** — source refreshes at most ~once/minute, so polling faster buys nothing. Resolved: refresh interval set to ~30–60s aligned to the source (ADR-0001 updated).

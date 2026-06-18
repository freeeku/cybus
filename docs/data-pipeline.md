# Data pipeline

How transit data flows from CyNAP to the app. There are two independent pieces of backend, both designed to run within free tiers (see [ADR-0001](./adr/0001-free-tier-first-realtime-architecture.md)). Verified source details are in [data-sources.md](./data-sources.md).

```
            STATIC (changes weekly/monthly)        REALTIME (changes every ~30–60s)

  CyNAP / motionbuscard                       CyNAP GTFS-RT
  7 GTFS .zip files                           http://20.19.98.194:8328/Api/api/gtfs-realtime
        │                                            │  (plain HTTP, combined protobuf)
        ▼                                            ▼
  ┌─────────────────────────┐                ┌─────────────────────────┐
  │ Scheduled job           │                │ Edge proxy              │
  │ (GitHub Action, cron)   │                │ (Cloudflare Worker)     │
  │ • download 7 zips       │                │ • fetch upstream once   │
  │ • validate (GTFS valid.)│                │   per ~30–60s           │
  │ • merge → 1 SQLite      │                │ • edge-cache snapshot   │
  │ • hash/sign             │                │ • serve over HTTPS      │
  │ • publish to static host│                │   to all devices        │
  └───────────┬─────────────┘                └───────────┬─────────────┘
              │ HTTPS, on version change                  │ HTTPS, ~30–60s poll
              ▼                                            ▼
  ┌───────────────────────────────────────────────────────────────────┐
  │                          iOS app                                    │
  │  • downloads SQLite once, refreshes on version change               │
  │  • polls proxy for realtime protobuf, decodes on-device             │
  │  • joins realtime (trip_id/route_id/stop_id) ↔ static SQLite        │
  │  • renders vehicles, stops, arrivals on MapKit                      │
  └───────────────────────────────────────────────────────────────────┘
```

## Piece 1 — Static GTFS job (scheduled)

**What it is:** a scheduled automation that turns the raw GTFS feeds into one ready-to-use SQLite file the app can download. The default runner is a **GitHub Action** on a cron schedule — it runs on GitHub's servers for free, needs no server of our own. Any scheduled runner works (Cloudflare Cron Triggers, etc.); GitHub Actions is just the zero-ops default.

**Cadence:** static GTFS changes rarely (route/stop edits), so running ~once a day is plenty.

**Steps each run:**
1. Download the 7 per-provider zips (EMEL, OSYPA, OSEA, NPT, LPT, Intercity, Pame Express).
2. **Validate** each with the MobilityData GTFS validator. If a feed is broken or hostile, fail the build and keep serving the last-good version.
3. Merge the 7 feeds into one compact **SQLite** (only the tables/columns the app needs: stops, routes, trips, shapes).
4. Compute a **SHA-256** (and optionally sign) so the app can verify integrity.
5. Publish the SQLite + a version/manifest to free static hosting.

**Download note:** the motionbuscard zip endpoint requires the `&rel=True` query param (verified working — see [data-sources.md](./data-sources.md)).

## Piece 2 — Realtime edge proxy (continuous)

**What it is:** a thin, stateless function (default: a **Cloudflare Worker**) that sits between the app and the CyNAP realtime feed. Rationale in [ADR-0001](./adr/0001-free-tier-first-realtime-architecture.md).

**Why it must exist (not optional):**
- CyNAP's realtime feed is **plain HTTP on an IP:port** — iOS App Transport Security blocks that from the app directly. The proxy fetches it server-side and serves HTTPS.
- **Edge-caching** one upstream fetch per ~30–60s and fanning it out keeps reads free at any scale.
- It's the place to hide/rotate upstream details and absorb feed changes without an app-store release.

**Behaviour:** on request, return the cached protobuf snapshot (cache window ~30–60s, matching CyNAP's "up to 1 minute" update cadence). The app decodes and does all joins on-device.

## Trust boundary

CyNAP / motionbuscard are **untrusted external input**. Validation happens at our two controlled pieces (the job validates GTFS; the proxy bounds message size and rejects unparseable protobuf). The app trusts only HTTPS-served, hash-verified artifacts and still range-checks values (e.g. coordinates) before rendering. See [security.md](./security.md) for specifics on zip-slip, zip bombs, protobuf size caps, and the SQLite integrity model.

# Free-tier-first realtime architecture

The obvious design for a live bus tracker is a small always-on backend that ingests GTFS + GTFS-realtime, joins it, and serves clean JSON to the app. We deliberately did **not** do this, because the headline constraint is staying within free tiers even at busonmap-scale (~18k users).

Instead:

- **Realtime** is served by a *thin, stateless serverless proxy* that polls the CyNAP GTFS-realtime feed once per ~30–60s and fans an **edge-cached** snapshot out to all devices. Edge caching means thousands of devices cost roughly one upstream fetch per cache window, so reads stay free at scale. The proxy also hides the upstream (a plain-HTTP IP:port that iOS ATS would otherwise block) and lets us absorb upstream feed changes without an app-store release.
- **Static GTFS** is converted to a compact SQLite by a free scheduled GitHub Action and published to free static hosting; the app downloads it once and refreshes only when the version changes.
- The **realtime↔static joins** (vehicle/trip → route, stop → upcoming arrivals) happen **on-device**, which is what keeps the proxy thin rather than letting it grow into a real backend.

**Why ~30–60s and not ~10s** (busonmap implies ~10s): CyNAP's published cadence is "up to 1 minute" — the source itself refreshes at most once per minute, so polling faster returns identical data and just burns requests and mobile data for nothing. A 30–60s window matches the source, keeps edge-cached reads effectively free at any scale, and is lightest on the user's data plan. We initially scoped ~15s before discovering the true upstream cadence (see `docs/data-sources.md`).

**Consequences:** no server-side place to compute things or store user state (acceptable — the MVP has no accounts and no favorites). If we ever outgrow the free tiers or need push notifications / server-side joins, this is the decision to revisit; accepting ~$5/mo for an always-on server is the natural next step.

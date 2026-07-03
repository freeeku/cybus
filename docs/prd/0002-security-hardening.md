# PRD 0002 — Security hardening: close the gap between the documented posture and the code

> Status: ready-for-agent. Vocabulary follows [CONTEXT.md](../../CONTEXT.md); respects [ADR-0001](../adr/0001-free-tier-first-realtime-architecture.md), [ADR-0002](../adr/0002-ios-only-native-swift.md), and the posture in [security.md](../security.md). No new product features — this PRD makes the code do what security.md already promises.

## Problem Statement

A security review (2026-07-04) found that [security.md](../security.md) describes a sound, proportionate posture — but several of its mitigations are documented, not implemented. The most serious drift: the app now talks **plain HTTP directly to CyNAP** with an ATS exception, bypassing the mandatory HTTPS proxy that ADR-0001, PRD-0001 (story 30), and security.md all assume. Other gaps (unbounded downloads, missing decompression caps, unpinned CI actions, silent degraded publishes, no last-good fallback in the app) each turn a bad feed day or an on-path attacker into a crashed or empty app.

The data is public and low-stakes; the threat model has not changed. The goal remains "don't crash, don't get DoS'd, don't trust a single source blindly" — implemented, not just written down.

## Findings being addressed

| ID | Severity | Finding | Where |
|----|----------|---------|-------|
| H1 | High | App bypasses proxy; plain-HTTP direct to CyNAP with ATS exception | `ios/Cybus/App/AppConfig.swift:10`, `ios/Cybus/Resources/Info.plist` |
| H2 | High | Realtime response buffered unbounded before the 5 MB cap is checked | `ios/Cybus/App/AppModel.swift` (`fetchAndApplyFeed`) |
| H3 | High | zlib decompression of the static SQLite has no output-size cap (decompression bomb) | `ios/Cybus/App/AppModel.swift` (`StaticDataManager.decompress`) |
| H4 | High | Static-data refresh failure discards the verified last-good local DB (app boots with no stops) | `ios/Cybus/App/AppModel.swift` (`refreshStaticData`) |
| M1 | Medium | CI actions pinned by mutable tag, not commit SHA; third-party publish action holds `contents: write`; pip deps not hash-pinned and incomplete | `.github/workflows/gtfs-pipeline.yml`, `pipeline/requirements.txt` |
| M2 | Medium | Provider downloads follow unlimited cross-host redirects | `pipeline/build_gtfs.py` (`download_provider`) |
| M3 | Medium | No cap on zip uncompressed size / entry count / compression ratio | `pipeline/build_gtfs.py` (`iter_gtfs_rows`) |
| M4 | Medium | Pipeline publishes silently-degraded data (missing providers, no validator gate) and non-atomically (manifest/blob can skew through the CDN) | `pipeline/build_gtfs.py`, workflow |
| L1 | Low | Worker error responses echo upstream error detail to clients | `proxy/src/worker.ts` (`errorResponse` callers) |
| L2 | Low | Worker `cache.put` lacks `ctx.waitUntil`; runtime may cancel it, defeating the edge cache | `proxy/src/worker.ts` |
| L3 | Low | CORS `*` set but no `OPTIONS` handling | `proxy/src/worker.ts` |
| L4 | Low | Displayed string lengths (stop names, headsigns) unbounded | pipeline + app |
| L5 | Low | `manifest.url`/`size_bytes` written but ignored by the app (config drift) | pipeline + `AppModel.swift` |
| L6 | Low | GTFS-RT arrival times not sanity-checked against a plausible window | `ios/Cybus/Domain/ArrivalBuilder.swift` |

## User Stories

1. As a rider on public Wi-Fi, I want all app traffic over HTTPS, so that no one on my network can inject fake buses or garbage data into my app. *(H1)*
2. As a rider, I want the app to survive a hostile or broken realtime response without crashing or ballooning memory, so that a bad feed day looks like "no live data", not a crash. *(H2, L6)*
3. As a rider, I want the app to survive a hostile or broken static-data publish, so that a bad build day leaves me on yesterday's stops rather than an empty map. *(H3, H4)*
4. As the maintainer, I want a degraded pipeline run (missing providers, invalid feed) to fail the publish and keep serving last-good, so that users never receive silently-broken data. *(M4)*
5. As the maintainer, I want the fetch tooling and CI supply chain pinned, so that the one attack the hash manifest can't catch — a malicious but validly-hashed publish — requires compromising a specific commit, not a mutable tag. *(M1)*
6. As the maintainer, I want the pipeline's own downloads bounded (redirects, inflation), so that a compromised or misbehaving upstream can't wedge or redirect the build. *(M2, M3)*
7. As the maintainer, I want the proxy to be boring: cache reliably, leak nothing, answer CORS correctly. *(L1, L2, L3)*

## Implementation Decisions

### 1. Restore the proxy as the only realtime path (H1) — the headline change

- Deploy the existing Worker on a `workers.dev` (or custom-domain) HTTPS endpoint; fill in `wrangler.toml` routes.
- Point `AppConfig.proxyBaseURL` at it; realtime endpoint becomes `/gtfs-rt`.
- **Delete the ATS exception** from `Info.plist` entirely. ATS then enforces at the OS level that the app can never regress to plain HTTP — the exception's absence *is* the control.
- Update `AppConfig` doc comments (they currently describe the bypass as intentional).
- If the direct connection was a deliberate workaround (e.g. the Worker wasn't deployed yet), record the reason in ADR-0001's history; the workaround still ends here.

### 2. Bound every byte the app ingests (H2, H3)

- **Realtime fetch:** enforce the 5 MB cap *during* download — `URLSession` delegate (or `bytes(from:)` async stream) that aborts once the running total exceeds `FeedDecoder.maxBytes`. Set an explicit request timeout (~15 s).
- **Static download:** cap the compressed download (e.g. 2× `manifest.size_bytes`, ceiling 200 MB) during transfer, and cap decompressed output — stream-inflate with `compression_stream` (or check `manifest.size_bytes` first and refuse to inflate past it + slack). Hash-verify as today.
- Manifest fetch: bound to something tiny (64 KB) and set a timeout.

### 3. Fail closed *to last-good*, not to nothing (H4)

- In `refreshStaticData`, on any `ensureFresh` failure, attempt to open the existing verified local `gtfs.sqlite` before surfacing an error. Only show `staticError` when there is genuinely no usable local DB.
- Distinguish UI copy: "using offline data from <date>" (stale-but-working) vs. "couldn't load stops" (nothing).
- `GTFSStore`'s own `integrity_check` remains the final gate on the local file.

### 4. Pipeline: publish good data or don't publish (M2, M3, M4)

- **Redirects:** `Session` with `max_redirects` ≤ 3 and a hook (or manual loop) rejecting redirects whose host ≠ `motionbuscard.org.cy`.
- **Zip inflation guards:** per security.md — cap total uncompressed size (e.g. 500 MB), entry count (e.g. 100), and per-entry compression ratio (e.g. 100:1); abort the provider on breach.
- **Degraded-publish gate:** publishing requires ≥ N providers succeeded (default: all 7; overridable via workflow input for known outages) *and* sanity floors on the output (min stop/route/trip counts, e.g. ≥ 80 % of previous run). Otherwise exit non-zero — the workflow fails, gh-pages keeps last-good.
- **Validator gate:** run the MobilityData `gtfs-validator` on each provider zip; ERROR-level findings fail that provider (feeding the ≥ N gate).
- **Atomic-ish publish:** name the blob by content (`gtfs-<sha256-prefix>.sqlite.zz`), publish it *alongside* the previous blob (`keep_files` or two-step deploy), then update `manifest.json` last; the app downloads the URL from the manifest (see L5). Manifest/blob CDN skew then becomes harmless — an old manifest points at a still-present old blob.

### 5. Supply chain (M1)

- Pin every action by full commit SHA with a `# vX.Y.Z` comment.
- Replace `peaceiris/actions-gh-pages` with the first-party `actions/upload-pages-artifact` + `actions/deploy-pages` flow (scoped `pages: write`/`id-token: write` permissions, no third-party code holding `contents: write`).
- `requirements.txt`: list *all* direct deps (requests, protobuf/gtfs-realtime bindings) and compile a hash-pinned lock (`pip-compile --generate-hashes`); install with `--require-hashes`.
- Set top-level `permissions: {}` in the workflow and grant per-job minimums.

### 6. Proxy polish (L1–L3)

- `errorResponse`: generic client-facing message; move `detail` to `console.error` only.
- Thread `ExecutionContext` through `handleRequest`; wrap `cache.put` in `ctx.waitUntil`.
- Answer `OPTIONS` with 204 + CORS headers; keep `Access-Control-Allow-Origin: *` (public data, no credentials).

### 7. Value hygiene (L4–L6)

- Pipeline truncates stored display strings (stop names, headsigns, route names) to a sane bound (e.g. 128 chars) at ingest; app truncates again at render as belt-and-braces.
- App uses `manifest.url` for the blob download **only after validating** it is HTTPS and same-origin with `staticBaseURL`; drop the field otherwise. Use `size_bytes` for the download cap in §2.
- `ArrivalBuilder` rejects RT arrival times outside `now − 5 min … now + 12 h`.

## Explicitly out of scope (unchanged non-goals from security.md)

- Cryptographic signing of the SQLite (revisit only if the static host becomes a target).
- Certificate pinning.
- Auth/rate-limiting on the proxy (public data; Cloudflare's free-tier protections suffice).
- Any PII/user-data controls (the app still collects none).

## Acceptance Criteria

1. `Info.plist` contains **no** `NSExceptionDomains`; the app fetches realtime data successfully via the HTTPS proxy; grepping the app source for `http://` yields no live endpoints.
2. A simulated oversized realtime response (> 5 MB) is aborted mid-transfer; the app continues on the previous snapshot; memory stays flat.
3. A crafted `.zz` inflating past the cap is rejected before full inflation; a hash-mismatched download is rejected; **in both cases the app opens the existing local DB** and shows stops.
4. Pipeline run with a provider redirecting off-host: that provider fails; with < N providers or below sanity floors: the job exits non-zero and gh-pages retains the previous manifest + blob.
5. A zip exceeding inflation caps fails its provider without wedging the job (test fixture in `pipeline/tests/`).
6. Workflow file: every `uses:` is a 40-char SHA; no third-party action has `contents: write`; `pip install` runs with `--require-hashes`.
7. Worker tests cover: generic error body (no upstream detail), `OPTIONS` → 204, `waitUntil`-wrapped cache put.
8. New/updated unit tests in `CybusTests` for: streaming size cap, decompression cap, last-good fallback, arrival-time window.
9. `docs/security.md` updated so every mitigation it lists maps to code (file references), keeping doc and implementation honest.

## Sequencing

1. **Wave 1 (High):** §1 proxy restore + ATS removal → §3 last-good fallback → §2 download/decompression bounds. Ship together; §1 is user-visible risk reduction, §3 protects against §4's stricter pipeline while it lands.
2. **Wave 2 (Medium):** §4 pipeline gates + atomic publish, §5 supply chain.
3. **Wave 3 (Low):** §6 proxy polish, §7 value hygiene, doc reconciliation (AC 9).

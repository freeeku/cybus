# Deployment runbook

Cybus has two backend pieces to deploy (both free-tier — see [ADR-0001](./adr/0001-free-tier-first-realtime-architecture.md)):

1. **Static GTFS** → built by the pipeline, published to **GitHub Pages**.
2. **Realtime proxy** → a **Cloudflare Worker**.

After both are live, fill in two values in [`ios/Cybus/App/AppConfig.swift`](../ios/Cybus/App/AppConfig.swift) and ship the app.

> **Prerequisites already done:** repo is pushed to GitHub (`origin` = `git@github.com:freeeku/cybus.git`, public). `AppConfig.staticBaseURL` is already set to `https://freeeku.github.io/cybus`.

---

## 1. Static GTFS on GitHub Pages

The pipeline (`pipeline/build_gtfs.py`) merges the 7 provider feeds into one
`gtfs.sqlite.zz` (zlib-compressed), writes `manifest.json` (version + SHA-256),
and the GitHub Action (`.github/workflows/gtfs-pipeline.yml`) publishes `dist/`
to the `gh-pages` branch root.

**One-time setup**
1. **Settings → Pages → Source:** "Deploy from a branch", Branch: `gh-pages` / `root`.
   (The first workflow run creates the `gh-pages` branch.)
2. **Settings → Secrets and variables → Actions → Variables:** add
   `STATIC_SQLITE_URL` = `https://freeeku.github.io/cybus/gtfs.sqlite.zz`.
3. Run the workflow once manually: **Actions → "Build & Publish Static GTFS" → Run workflow**
   (it otherwise runs daily at 03:00 UTC).

**Verify**
```sh
curl -fsSL https://freeeku.github.io/cybus/manifest.json
curl -fsSI https://freeeku.github.io/cybus/gtfs.sqlite.zz   # expect 200, HTTPS
```

**Run the pipeline locally** (optional, to produce/inspect the artifact without CI):
```sh
cd pipeline
uv venv && uv pip install -r requirements.txt
.venv/bin/python build_gtfs.py --out-dir dist/
#  → dist/gtfs.sqlite.zz + dist/manifest.json
```

---

## 2. Realtime proxy on Cloudflare Workers

The Worker (`proxy/src/worker.ts`) fetches the CyNAP GTFS-RT feed once per cache
window and serves an HTTPS, edge-cached snapshot at `/gtfs-rt`.

**Prereqs:** a Cloudflare account, Node/npm installed locally.

```sh
cd proxy
npm install
npx wrangler login            # interactive browser OAuth
npx wrangler deploy           # prints the deployed URL
# sanity check:
curl -fsSL https://cybus-proxy.droid4dani.workers.dev/health
```

`AppConfig.proxyBaseURL` is already set to `https://cybus-proxy.droid4dani.workers.dev`.
If `wrangler deploy` prints a different subdomain, update that constant and rebuild.

---

## 3. Point the app at production

[`ios/Cybus/App/AppConfig.swift`](../ios/Cybus/App/AppConfig.swift) already has
both URLs set:

```swift
static let proxyBaseURL  = URL(string: "https://cybus-proxy.droid4dani.workers.dev")!
static let staticBaseURL = URL(string: "https://freeeku.github.io/cybus")!
```

If the Worker lands on a different subdomain after `wrangler deploy`, update
`proxyBaseURL`. Then rebuild and run (see [ios-build.md](./ios-build.md)).

---

## What needs accounts / can't be automated from the repo

| Step | Needs |
|------|-------|
| Enable Pages, run Actions, set `STATIC_SQLITE_URL` variable | GitHub repo settings |
| Deploy Worker (`wrangler login` + `wrangler deploy`) | Cloudflare account, Node |
| Update `AppConfig.proxyBaseURL` if subdomain differs | two-line edit + rebuild |

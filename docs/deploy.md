# Deployment runbook

Cybus has two backend pieces to deploy (both free-tier — see [ADR-0001](./adr/0001-free-tier-first-realtime-architecture.md)):

1. **Static GTFS** → built by the pipeline, published to **GitHub Pages**.
2. **Realtime proxy** → a **Cloudflare Worker**.

After both are live, fill in two values in [`ios/Cybus/App/AppConfig.swift`](../ios/Cybus/App/AppConfig.swift) and ship the app.

> Prerequisite: the repo must be pushed to GitHub (Actions + Pages need it).
> ```sh
> git remote add origin git@github.com:<you>/cybus.git
> git push -u origin master
> ```

---

## 1. Static GTFS on GitHub Pages

The pipeline (`pipeline/build_gtfs.py`) merges the 7 provider feeds into one
`gtfs.sqlite`, writes `manifest.json` (version + SHA-256), and the GitHub Action
(`.github/workflows/gtfs-pipeline.yml`) publishes `dist/` to the `gh-pages`
branch root.

**One-time setup**
1. **Settings → Pages → Source:** "Deploy from a branch", Branch: `gh-pages` / `root`.
   (The first workflow run creates the `gh-pages` branch.)
2. **Settings → Secrets and variables → Actions → Variables:** add
   `STATIC_SQLITE_URL` = `https://<user>.github.io/<repo>/gtfs.sqlite`.
3. Run the workflow once manually: **Actions → "Build & Publish Static GTFS" → Run workflow**
   (it otherwise runs daily at 03:00 UTC).

**Verify**
```sh
curl -fsSL https://<user>.github.io/<repo>/manifest.json
curl -fsSI https://<user>.github.io/<repo>/gtfs.sqlite   # expect 200, HTTPS
```

**Run the pipeline locally** (optional, to produce/inspect the artifact without CI):
```sh
cd pipeline
python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
./.venv/bin/python build_gtfs.py --out-dir dist/
#  → dist/gtfs.sqlite + dist/manifest.json
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
curl -fsSL https://cybus-proxy.<your-subdomain>.workers.dev/health
```

The default `*.workers.dev` URL is fine. To use a custom domain, set the
`routes` block in `proxy/wrangler.toml`.

---

## 3. Point the app at production

Edit [`ios/Cybus/App/AppConfig.swift`](../ios/Cybus/App/AppConfig.swift):

```swift
static let proxyBaseURL  = URL(string: "https://cybus-proxy.<your-subdomain>.workers.dev")!
static let staticBaseURL = URL(string: "https://<user>.github.io/<repo>")!
```

Both must be HTTPS. Rebuild and run (see [ios-build.md](./ios-build.md)).

---

## What needs accounts / can't be automated from the repo

| Step | Needs |
|------|-------|
| Push repo, run Actions, enable Pages | GitHub account + repo |
| `STATIC_SQLITE_URL` variable | GitHub repo settings |
| Deploy Worker | Cloudflare account, Node, `wrangler login` |
| Fill `AppConfig.swift` | the two URLs from the steps above |

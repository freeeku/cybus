# Handoff — current status & how to resume (incl. on another Mac)

Snapshot for picking the project back up, e.g. on a different machine.
Last updated: 2026-06-21 (tests added; deploy.md updated with real URLs).

## Where things are

All work is committed on branch `master` and **pushed to GitHub** — `master`
tracks `origin/master`, so this checkout is no longer the only copy.
- Remote: `origin` → https://github.com/freeeku/cybus (**public**, created 2026-06-20).

Done and verified (`xcodebuild test` on iPhone 17 / iOS 26.5 → 23 tests pass):
- iOS app builds; domain layer, map, stop sheet all in place.
- **Stops render on the map and are tappable** → stop-detail + arrivals flow works.
- **GTFS-realtime protobuf decoding is real** (SwiftProtobuf), not a stub → live
  vehicles + live arrivals.
- Pipeline (`pipeline/build_gtfs.py`) + CI wired to publish static GTFS to GitHub Pages.
- **43 unit tests passing** (27 pipeline + 16 proxy).
- `AppConfig.swift` has both URLs pre-filled (see below).

Not done yet:
- Backend not deployed; pipeline never run for real (no `gtfs.sqlite.zz` published).

## Set up on a new Mac

1. **Get the code:** since the repo is public, just clone it:
   ```sh
   git clone git@github.com:freeeku/cybus.git && cd cybus
   ```

2. **Install the toolchain:**
   - **Xcode** + an **iOS simulator runtime** (Xcode alone isn't enough — download
     a runtime via Xcode → Settings → Components, or `xcodebuild -downloadPlatform iOS`).
   - `brew install xcodegen protobuf swift-protobuf uv`
     (`xcodegen` is required; `protoc`/`protoc-gen-swift` only if regenerating the
     proto — the generated file is committed.)
   - **Node/npm** only if touching the proxy.

3. **Regenerate per-machine artifacts** (do not copy these):
   ```sh
   cd ios && xcodegen generate                 # recreate Cybus.xcodeproj
   cd ../pipeline && uv venv && uv pip install -r requirements-dev.txt
   ```

4. **Verify:**
   ```sh
   # iOS tests (23 passing)
   cd ios
   xcodebuild test -project Cybus.xcodeproj -scheme Cybus \
     -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
     -derivedDataPath .build CODE_SIGNING_ALLOWED=NO

   # Pipeline tests (27 passing)
   cd pipeline && .venv/bin/pytest tests/ -q

   # Proxy tests (16 passing)
   cd proxy && npm test
   ```
   Swap the simulator name/OS for whatever runtime you installed.

## Remaining deployment (needs your accounts)

Full commands in [deploy.md](./deploy.md). Summary:

1. **GitHub Pages:** Settings → Pages → `gh-pages`/root; add Actions variable
   `STATIC_SQLITE_URL = https://freeeku.github.io/cybus/gtfs.sqlite.zz`;
   run the "Build & Publish Static GTFS" workflow once.
2. **Cloudflare Worker:** `cd proxy && npx wrangler login && npx wrangler deploy`
   (needs a Cloudflare account + Node). `AppConfig.proxyBaseURL` is already set
   to `https://cybus-proxy.droid4dani.workers.dev` — update only if the subdomain differs.
3. **`AppConfig.swift`** already has both URLs set. Rebuild once backend is live.

Optional: run the pipeline locally — `cd pipeline && .venv/bin/python build_gtfs.py --out-dir dist/`.

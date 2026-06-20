# Handoff — current status & how to resume (incl. on another Mac)

Snapshot for picking the project back up, e.g. on a different machine.
Last updated: 2026-06-20.

## Where things are

All work is committed on branch `master`. **No git remote yet — this checkout
is the only copy until you push it.**

Done and verified (`xcodebuild test` on iPhone 17 / iOS 26.5 → 23 tests pass):
- iOS app builds; domain layer, map, stop sheet all in place.
- **Stops render on the map and are tappable** → stop-detail + arrivals flow works.
- **GTFS-realtime protobuf decoding is real** (SwiftProtobuf), not a stub → live
  vehicles + live arrivals.
- Pipeline (`pipeline/build_gtfs.py`) + CI wired to publish static GTFS to GitHub Pages.
- Endpoints centralized in `ios/Cybus/App/AppConfig.swift` (two URLs to fill on deploy).

Not done yet:
- Backend not deployed; `AppConfig.swift` still has placeholder URLs.
- Pipeline never run for real (no `gtfs.sqlite` published).
- No pipeline/proxy unit tests (PRD asks for them).

## Set up on a new Mac

1. **Get the code there.** Either push to GitHub and clone, or move a single
   bundle (keeps full history, skips the ~830 MB build cache):
   ```sh
   # on this Mac:
   git bundle create cybus.bundle --all
   # AirDrop cybus.bundle over, then on the new Mac:
   git clone cybus.bundle cybus && cd cybus
   ```
   If copying the folder directly instead, exclude: `ios/.build/`,
   `ios/Cybus.xcodeproj/`, `pipeline/__pycache__/`, any `.venv`/`node_modules`.

2. **Install the toolchain:**
   - **Xcode** + an **iOS simulator runtime** (Xcode alone isn't enough — download
     a runtime via Xcode → Settings → Components, or `xcodebuild -downloadPlatform iOS`).
   - `brew install xcodegen protobuf swift-protobuf`
     (`xcodegen` is required; `protoc`/`protoc-gen-swift` only if regenerating the
     proto — the generated file is committed.)
   - **Python 3.12+** (pipeline). **Node/npm** only if touching the proxy.

3. **Regenerate per-machine artifacts** (do not copy these):
   ```sh
   cd ios && xcodegen generate                 # recreate Cybus.xcodeproj
   cd ../pipeline && python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
   ```

4. **Verify:**
   ```sh
   cd ios
   xcodebuild test -project Cybus.xcodeproj -scheme Cybus \
     -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
     -derivedDataPath .build CODE_SIGNING_ALLOWED=NO
   ```
   (Swap the simulator name/OS for whatever runtime you installed.) Expect 23 passing.

## Remaining deployment (needs your accounts)

Full commands in [deploy.md](./deploy.md). Summary of what only you can do:

1. **Push to GitHub** (`git remote add origin …` then `git push -u origin master`).
   Note: `gh` CLI auth was failing locally (`freeeku` keyring) — fix or use the browser.
2. **GitHub Pages:** Settings → Pages → `gh-pages`/root; add Actions **variable**
   `STATIC_SQLITE_URL = https://<user>.github.io/<repo>/gtfs.sqlite`; run the
   "Build & Publish Static GTFS" workflow once.
3. **Cloudflare Worker:** `cd proxy && npm install && npx wrangler login && npx wrangler deploy`
   (needs a Cloudflare account + Node).
4. **Fill `ios/Cybus/App/AppConfig.swift`** with the Worker origin + Pages base, rebuild.

Optional anytime: run the pipeline locally to produce/inspect a real artifact —
`cd pipeline && ./.venv/bin/python build_gtfs.py --out-dir dist/`.

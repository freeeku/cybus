# iOS build & verification

The iOS app is generated with **xcodegen** from `ios/project.yml` (no checked-in `.xcodeproj`). Deps: GRDB + SwiftProtobuf. Targets iOS 17+, Swift 6 with `ENABLE_STRICT_CONCURRENCY: complete`.

## Build locally

```sh
brew install xcodegen          # one-time
cd ios && xcodegen generate    # produces Cybus.xcodeproj
xcodebuild -scheme Cybus -destination 'generic/platform=iOS' build
# or just: open Cybus.xcodeproj
```

> The iOS target cannot be compiled in environments without Xcode/the iOS SDK (e.g. CI agents or Claude Code's sandbox). Treat Swift changes made there as reviewed-by-reading, not compiler-verified, and build locally before pushing.

## SQLite-in-Swift gotchas (handled in `GTFSStore.swift`)

- `SQLITE_TRANSIENT` / `SQLITE_STATIC` are function-pointer-cast C macros that Swift can't import — define manually:
  `let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)`.
- Any file that uses `Color` needs `import SwiftUI` (imports are per-file).
- A protocol witness must match the requirement's full signature exactly — a method with an extra **defaulted** parameter does **not** satisfy a fewer-parameter requirement. Provide the exact-signature method and delegate to the wider one.

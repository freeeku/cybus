# iOS-only, native Swift (SwiftUI + MapKit)

We are building a native iOS app with SwiftUI and Apple MapKit, and deliberately **not** targeting Android or using a cross-platform framework (React Native / Flutter) for the MVP.

**Why:**

- **MapKit is free.** A live map app's biggest recurring risk is per-map-load / per-tile billing (Mapbox, Google Maps). Apple MapKit has no such bill on iOS, which fits the free-tier-first constraint ([[0001-free-tier-first-realtime-architecture]]).
- Native gives the best map rendering and polish for the one platform we ship.
- Being native also means **no CORS constraint**, so the app can talk to the edge-cached feed proxy (and could even poll feeds directly) without browser-style restrictions.

**The trade-off:** we reach only iOS users and forgo the cheaper-phone Android audience that a bus app arguably serves well. Adding Android later means a second codebase (or a rewrite onto a cross-platform stack), since none of the Swift/MapKit work carries over. We accepted this to keep the MVP small, free, and polished on one platform.

**Cost note:** this introduces the project's only guaranteed fixed cost — the **$99/yr Apple Developer Program** fee.

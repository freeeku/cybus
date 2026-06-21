import Foundation

/// The only values that change when the backend is deployed. Everything else in
/// the app derives its endpoints from here, so a deploy is a two-line edit.
///
/// After deploying, set:
///  - `proxyBaseURL`  → the Cloudflare Worker (realtime proxy) origin, e.g.
///                      https://cybus-proxy.<your-subdomain>.workers.dev
///  - `staticBaseURL` → where the pipeline publishes gtfs.sqlite + manifest.json.
///                      For GitHub Pages (repo named `cybus`):
///                      https://<your-github-user>.github.io/cybus
///
/// Both must be HTTPS (iOS App Transport Security blocks plain HTTP, and the
/// static trust model is HTTPS + SHA-256 verification — see docs/security.md).
/// See docs/deploy.md for the full deployment runbook.
enum AppConfig {

    /// Realtime proxy origin — no trailing slash, no path.
    static let proxyBaseURL = URL(string: "https://cybus-proxy.YOUR_SUBDOMAIN.workers.dev")!

    /// Static artifact base — no trailing slash. The pipeline publishes
    /// `manifest.json` and `gtfs.sqlite` directly under this URL.
    static let staticBaseURL = URL(string: "https://YOUR_GITHUB_USER.github.io/cybus")!

    // MARK: - Derived endpoints

    /// GTFS-realtime protobuf snapshot served by the proxy.
    static var realtimeFeedURL: URL { proxyBaseURL.appendingPathComponent("gtfs-rt") }

    /// Version manifest the app checks before downloading the SQLite.
    static var manifestURL: URL { staticBaseURL.appendingPathComponent("manifest.json") }

    /// The zlib-compressed GTFS SQLite the app downloads, decompresses, and caches.
    static var sqliteURL: URL { staticBaseURL.appendingPathComponent("gtfs.sqlite.zz") }
}

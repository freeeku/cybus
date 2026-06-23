import Foundation

/// Central endpoint config. Edit here when the backend changes.
///
/// Realtime goes direct to the CyNAP upstream over plain HTTP (ATS exception in Info.plist).
/// Static GTFS is served from GitHub Pages over HTTPS.
enum AppConfig {

    /// Realtime feed origin — direct to the CyNAP upstream (plain HTTP, ATS exception in Info.plist).
    static let proxyBaseURL = URL(string: "http://20.19.98.194:8328")!

    /// Static artifact base — no trailing slash. The pipeline publishes
    /// `manifest.json` and `gtfs.sqlite.zz` directly under this URL.
    static let staticBaseURL = URL(string: "https://freeeku.github.io/cybus")!

    // MARK: - Derived endpoints

    /// GTFS-realtime protobuf — direct CyNAP endpoint.
    static var realtimeFeedURL: URL { proxyBaseURL.appendingPathComponent("Api/api/gtfs-realtime") }

    /// Version manifest the app checks before downloading the SQLite.
    static var manifestURL: URL { staticBaseURL.appendingPathComponent("manifest.json") }

    /// The zlib-compressed GTFS SQLite the app downloads, decompresses, and caches.
    static var sqliteURL: URL { staticBaseURL.appendingPathComponent("gtfs.sqlite.zz") }
}

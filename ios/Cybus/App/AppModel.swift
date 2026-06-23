import SwiftUI
import MapKit
import Combine
import CommonCrypto

// MARK: - AppModel
//
// The single source of truth for the running app. Drives:
//   • Static GTFS download + version check
//   • Realtime feed polling (foreground only, ~60s)
//   • Derived state: [Vehicle], selected Stop, Arrivals

@MainActor
@Observable
final class AppModel {

    // MARK: - Public state (read by views)

    var vehicles: [Vehicle] = []
    var stops: [Stop] = []              // Stops visible at the current zoom (empty when zoomed out)
    var selectedStop: Stop?
    var arrivals: [Arrival] = []
    var trackedVehicle: Vehicle?        // highlighted + followed when user taps an Arrival

    /// Current map region; persisted to UserDefaults as last-viewed region.
    var mapRegion: MKCoordinateRegion = AppModel.defaultRegion

    var isLoadingStatic = false
    var staticError: String?

    /// Returns the route polyline for display on the map. Nil if the static store isn't loaded yet.
    func routeShape(forRoute routeId: String) -> [CLLocationCoordinate2D]? {
        store?.shape(forRoute: routeId)
    }

    // MARK: - Private

    private var store: (any GTFSStoreProtocol)?
    private var latestFeed = FeedMessage(timestamp: .distantPast, entities: [])

    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    // Endpoints live in AppConfig — the single place to edit after deploying.
    private static let proxyURL = AppConfig.realtimeFeedURL
    private static let manifestURL = AppConfig.manifestURL
    private static let sqliteURL = AppConfig.sqliteURL

    /// True when no persisted region was restored, i.e. this is effectively a
    /// first launch. The map uses this to decide whether to auto-center on the
    /// user's location (we don't override a region the user last looked at).
    let startedAtDefaultRegion: Bool

    // MARK: - Init

    init() {
        let persisted = AppModel.loadPersistedRegion()
        mapRegion = persisted ?? Self.defaultRegion
        startedAtDefaultRegion = (persisted == nil)
        Task { await startUp() }
    }

    // MARK: - Lifecycle

    /// Called when the app moves to foreground.
    func didEnterForeground() {
        startPolling()
    }

    /// Called when the app moves to background. Stops polling to save battery & data.
    func didEnterBackground() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Stop selection

    func selectStop(_ stop: Stop) {
        selectedStop = stop
        trackedVehicle = nil
        rebuildArrivals(for: stop)
    }

    func dismissStop() {
        selectedStop = nil
        arrivals = []
        trackedVehicle = nil
    }

    /// Called when user taps an Arrival row to track/highlight its Vehicle.
    func trackArrival(_ arrival: Arrival) {
        trackedVehicle = ArrivalBuilder.resolveVehicle(in: vehicles, for: arrival)
    }

    // MARK: - Stops on the map

    /// Span (in degrees latitude) below which individual Stops are shown. Above
    /// this the map would be an unreadable wall of pins (PRD story 7), so we
    /// show none.
    private static let stopZoomThreshold: Double = 0.08

    /// Maximum Stops loaded for a single view, as a backstop against a dense
    /// bounding box. The zoom gate keeps real-world counts well under this.
    private static let stopQueryLimit = 400

    /// Recomputes the visible Stops for the given map region. Clears them when
    /// zoomed out past the threshold or before the static store has loaded.
    func updateVisibleStops(for region: MKCoordinateRegion) {
        guard let store, region.span.latitudeDelta < Self.stopZoomThreshold else {
            if !stops.isEmpty { stops = [] }
            return
        }
        let bounds = CoordinateBounds(
            minLat: region.center.latitude - region.span.latitudeDelta / 2,
            maxLat: region.center.latitude + region.span.latitudeDelta / 2,
            minLon: region.center.longitude - region.span.longitudeDelta / 2,
            maxLon: region.center.longitude + region.span.longitudeDelta / 2
        )
        stops = store.stops(in: bounds, limit: Self.stopQueryLimit)
    }

    // MARK: - Map region persistence

    func saveRegion(_ region: MKCoordinateRegion) {
        mapRegion = region
        let d: [String: Double] = [
            "lat": region.center.latitude,
            "lon": region.center.longitude,
            "dLat": region.span.latitudeDelta,
            "dLon": region.span.longitudeDelta
        ]
        UserDefaults.standard.set(d, forKey: "lastMapRegion")
    }

    // MARK: - Private startup

    private func startUp() async {
        await refreshStaticData()
        startPolling()
    }

    @MainActor
    private func refreshStaticData() async {
        isLoadingStatic = true
        staticError = nil
        defer { isLoadingStatic = false }

        do {
            let localURL = try await StaticDataManager.ensureFresh(
                manifestURL: Self.manifestURL,
                sqliteURL: Self.sqliteURL
            )
            store = try GTFSStore(url: localURL)
            // The map may already be zoomed into a city (restored region), so
            // populate Stops now rather than waiting for the next camera move.
            updateVisibleStops(for: mapRegion)
        } catch {
            staticError = error.localizedDescription
        }
    }

    private func startPolling() {
        guard pollTask == nil || pollTask!.isCancelled else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await fetchAndApplyFeed()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    @MainActor
    private func fetchAndApplyFeed() async {
        guard let data = try? await URLSession.shared.data(from: Self.proxyURL).0 else { return }
        guard let feed = try? FeedDecoder.decode(data) else { return }

        latestFeed = feed

        guard let store else { return }
        vehicles = ArrivalBuilder.buildVehicles(store: store, feed: feed)

        // Keep the tracked vehicle's position/highlight current as the feed
        // updates. Drops tracking if the vehicle has left the feed.
        if let tracked = trackedVehicle {
            trackedVehicle = vehicles.first { $0.id == tracked.id }
        }

        if let stop = selectedStop {
            rebuildArrivals(for: stop)
        }
    }

    /// Recomputes arrivals for the current stop against a fresh `now`,
    /// without disturbing stop selection or the tracked vehicle.
    func refreshArrivals() {
        guard let stop = selectedStop else { return }
        rebuildArrivals(for: stop)
    }

    private func rebuildArrivals(for stop: Stop) {
        guard let store else { return }
        arrivals = ArrivalBuilder.buildArrivals(
            store: store, feed: latestFeed, stopId: stop.id, now: Date()
        )
    }

    // MARK: - Helpers

    private static func loadPersistedRegion() -> MKCoordinateRegion? {
        guard let d = UserDefaults.standard.dictionary(forKey: "lastMapRegion") as? [String: Double],
              let lat = d["lat"], let lon = d["lon"],
              let dLat = d["dLat"], let dLon = d["dLon"] else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            span: MKCoordinateSpan(latitudeDelta: dLat, longitudeDelta: dLon)
        )
    }

    // Cyprus island default view
    static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.126, longitude: 33.430),
        span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.5)
    )

    /// Rough bounding box for Cyprus. The map auto-centers on the user only when
    /// they're on the island — a user opening the app abroad keeps the default
    /// island overview rather than being yanked to wherever they are.
    static func isInCyprus(_ c: CLLocationCoordinate2D) -> Bool {
        (34.4...35.8).contains(c.latitude) && (32.0...34.7).contains(c.longitude)
    }
}

// MARK: - StaticDataManager

/// Handles manifest check + SQLite download + SHA-256 verification.
enum StaticDataManager {

    private struct Manifest: Decodable {
        let version: String
        let sha256: String          // SHA-256 of the *uncompressed* SQLite
        let compression: String?    // "zlib" when the download is zlib-compressed
        let url: String
    }

    static func ensureFresh(manifestURL: URL, sqliteURL: URL) async throws -> URL {
        let localDB = localSQLiteURL()
        let manifest = try await fetchManifest(from: manifestURL)

        // If we already have the right version, skip download
        if let stored = storedVersion(), stored == manifest.version,
           FileManager.default.fileExists(atPath: localDB.path) {
            return localDB
        }

        // Download compressed blob, then decompress + verify
        let (tempURL, _) = try await URLSession.shared.download(from: sqliteURL)
        let rawData = try Data(contentsOf: tempURL)
        let sqliteData = try decompress(rawData, compression: manifest.compression)
        let hash = sha256(of: sqliteData)

        guard hash.lowercased() == manifest.sha256.lowercased() else {
            throw StaticDataError.hashMismatch(expected: manifest.sha256, got: hash)
        }

        // Atomically replace
        _ = try? FileManager.default.removeItem(at: localDB)
        try sqliteData.write(to: localDB, options: .atomic)
        storeVersion(manifest.version)

        return localDB
    }

    private static func decompress(_ data: Data, compression: String?) throws -> Data {
        guard compression == "zlib" else { return data }
        // NSData.decompressed(using: .zlib) expects raw DEFLATE (RFC 1951).
        // Python's zlib.compress() emits zlib-wrapped format (RFC 1950) with a
        // 2-byte header and 4-byte Adler-32 trailer — strip those first.
        guard data.count > 6 else { throw StaticDataError.decompressionFailed }
        // Force a copy (not a slice) — NSData bridging can behave unexpectedly with
        // non-zero-based Data slices on some runtime versions.
        let rawDeflate = Data(data[2 ..< data.count - 4])
        return try (rawDeflate as NSData).decompressed(using: .zlib) as Data
    }

    private static func fetchManifest(from url: URL) async throws -> Manifest {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func sha256(of data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func localSQLiteURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gtfs.sqlite")
    }

    private static func storedVersion() -> String? {
        UserDefaults.standard.string(forKey: "gtfsVersion")
    }

    private static func storeVersion(_ v: String) {
        UserDefaults.standard.set(v, forKey: "gtfsVersion")
    }
}

enum StaticDataError: Error, LocalizedError {
    case hashMismatch(expected: String, got: String)
    case decompressionFailed
    var errorDescription: String? {
        switch self {
        case .hashMismatch(let e, let g):
            return "SQLite hash mismatch — expected \(e), got \(g). Download discarded."
        case .decompressionFailed:
            return "Failed to decompress GTFS SQLite (zlib). Download discarded."
        }
    }
}

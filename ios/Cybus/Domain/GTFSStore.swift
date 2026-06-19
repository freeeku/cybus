import Foundation
import CoreLocation
import SwiftUI
import SQLite3

// SQLite's destructor sentinels are function-pointer-cast C macros that Swift
// cannot import, so we define them here (the classic SQLite-in-Swift gotcha).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Protocol (mockable in tests)

protocol GTFSStoreProtocol {
    /// Route metadata by route_id.
    func route(id: String) -> RouteInfo?
    /// route_id for a given trip_id (JOIN trips → routes).
    func routeId(forTrip tripId: String) -> String?
    /// Headsign for a trip.
    func headsign(forTrip tripId: String) -> String?
    /// Ordered shape polyline for a route (first shape found for any trip on that route).
    func shape(forRoute routeId: String) -> [CLLocationCoordinate2D]
    /// Trips serving stopId with a scheduled arrival after `after`, within the next 3 hours.
    func upcomingTrips(stopId: String, after: Date) -> [ScheduledTrip]
}

// MARK: - Live SQLite implementation

/// Reads the static GTFS SQLite file produced by the build pipeline.
/// All queries are read-only and synchronous (called on a background actor).
final class GTFSStore: GTFSStoreProtocol {

    private let db: OpaquePointer

    // In-memory caches (populated on first access)
    private var routeCache: [String: RouteInfo] = [:]
    private var tripRouteCache: [String: String] = [:]      // tripId → routeId
    private var tripHeadsignCache: [String: String] = [:]   // tripId → headsign

    // Service-calendar caches (for filtering scheduled trips by day-of-service)
    private var serviceRules: [String: ServiceRule] = [:]
    private var serviceExceptions: [String: [Int: Int]] = [:]  // serviceId → (yyyymmdd → exception_type)
    private var activeServiceCache: [Int: Set<String>] = [:]   // yyyymmdd → active serviceIds
    private var hasCalendarData = false

    private struct ServiceRule {
        let days: [Bool]   // index 0 = Monday … 6 = Sunday
        let startInt: Int  // yyyymmdd inclusive
        let endInt: Int    // yyyymmdd inclusive
    }

    private struct StopTimeCandidate {
        let tripId: String
        let routeId: String
        let serviceId: String
        let seconds: Int   // seconds from midnight of its own service day
    }

    // MARK: - Init / deinit

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
              let opened = handle else {
            throw GTFSStoreError.cannotOpen(url)
        }
        db = opened

        // Verify integrity (fast; reads page checksum)
        try verifyIntegrity()
        // Warm caches for hot-path lookups
        try warmCaches()
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - GTFSStoreProtocol

    func route(id: String) -> RouteInfo? {
        routeCache[id]
    }

    func routeId(forTrip tripId: String) -> String? {
        tripRouteCache[tripId]
    }

    func headsign(forTrip tripId: String) -> String? {
        tripHeadsignCache[tripId]
    }

    func shape(forRoute routeId: String) -> [CLLocationCoordinate2D] {
        // Find the first shape_id associated with any trip on this route, then load points.
        guard let shapeId = firstShapeId(forRoute: routeId) else { return [] }
        return shapePoints(shapeId: shapeId)
    }

    // Protocol witness — exact signature required for conformance. Delegates to
    // the windowed implementation with the default 3-hour horizon.
    func upcomingTrips(stopId: String, after: Date) -> [ScheduledTrip] {
        upcomingTrips(stopId: stopId, after: after, windowHours: 3)
    }

    /// Scheduled arrivals at `stopId` within the next `windowHours`, filtered by
    /// the GTFS service calendar so trips that don't run on the relevant day are
    /// excluded. Handles after-midnight service (GTFS times ≥ 24:00:00) on both
    /// today's and yesterday's service day.
    func upcomingTrips(stopId: String, after: Date, windowHours: Int) -> [ScheduledTrip] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: after)
        let afterSeconds = Int(after.timeIntervalSince(today))
        let cutoffSeconds = afterSeconds + windowHours * 3600

        let candidates = stopTimeCandidates(stopId: stopId)
        guard !candidates.isEmpty else { return [] }

        // Services running on each relevant calendar day. `nil` means the SQLite
        // carries no calendar data, in which case we don't filter (degrade
        // gracefully to "all services active").
        let todayServices = activeServiceIds(on: today)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let yesterdayServices = activeServiceIds(on: yesterday)

        func isActive(_ services: Set<String>?, _ serviceId: String) -> Bool {
            services == nil || services!.contains(serviceId)
        }

        var results: [ScheduledTrip] = []
        for c in candidates {
            // 1. Today's service: trip departs `seconds` into today. A value
            //    ≥ 86_400 is a today-service trip running after midnight, which
            //    a window straddling midnight may legitimately reach.
            if c.seconds >= afterSeconds, c.seconds <= cutoffSeconds,
               isActive(todayServices, c.serviceId) {
                let date = today.addingTimeInterval(TimeInterval(c.seconds))
                results.append(ScheduledTrip(tripId: c.tripId, routeId: c.routeId, arrivalTime: date))
                continue
            }
            // 2. Yesterday's after-midnight service spilling into this morning:
            //    a trip with seconds ≥ 24:00:00 on yesterday's service arrives at
            //    (seconds − 86_400) into today.
            if c.seconds >= 86_400, isActive(yesterdayServices, c.serviceId) {
                let shifted = c.seconds - 86_400
                if shifted >= afterSeconds, shifted <= cutoffSeconds {
                    let date = today.addingTimeInterval(TimeInterval(shifted))
                    results.append(ScheduledTrip(tripId: c.tripId, routeId: c.routeId, arrivalTime: date))
                }
            }
        }
        return results
    }

    /// All (trip, route, service, seconds-from-midnight) rows serving `stopId`.
    private func stopTimeCandidates(stopId: String) -> [StopTimeCandidate] {
        let sql = """
            SELECT st.trip_id, t.route_id, t.service_id, st.arrival_time
            FROM stop_times st
            JOIN trips t ON t.trip_id = st.trip_id
            WHERE st.stop_id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, stopId, -1, SQLITE_TRANSIENT)

        var rows: [StopTimeCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let tripIdC = sqlite3_column_text(stmt, 0),
                  let routeIdC = sqlite3_column_text(stmt, 1),
                  let timeStrC = sqlite3_column_text(stmt, 3),
                  let seconds = parseGTFSTime(String(cString: timeStrC)) else { continue }
            let serviceId = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            rows.append(StopTimeCandidate(
                tripId: String(cString: tripIdC),
                routeId: String(cString: routeIdC),
                serviceId: serviceId,
                seconds: seconds
            ))
        }
        return rows
    }

    /// Service IDs active on `date`, or `nil` when the SQLite has no calendar
    /// data (caller treats `nil` as "do not filter").
    private func activeServiceIds(on date: Date) -> Set<String>? {
        guard hasCalendarData else { return nil }
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let y = comps.year, let m = comps.month, let d = comps.day,
              let wd = comps.weekday else { return nil }
        let dateInt = y * 10_000 + m * 100 + d
        if let cached = activeServiceCache[dateInt] { return cached }

        // GTFS weekday columns run Monday…Sunday; Calendar weekday is 1=Sun…7=Sat.
        let gtfsIndex = (wd + 5) % 7   // Mon→0 … Sun→6

        var active = Set<String>()
        for (sid, rule) in serviceRules
        where dateInt >= rule.startInt && dateInt <= rule.endInt && rule.days[gtfsIndex] {
            active.insert(sid)
        }
        for (sid, byDate) in serviceExceptions {
            switch byDate[dateInt] {
            case 1: active.insert(sid)   // service added on this date
            case 2: active.remove(sid)   // service removed on this date
            default: break
            }
        }
        activeServiceCache[dateInt] = active
        return active
    }

    // MARK: - Private helpers

    private func verifyIntegrity() throws {
        let sql = "PRAGMA integrity_check(1)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GTFSStoreError.integrityFailed("could not prepare pragma")
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW,
           let result = sqlite3_column_text(stmt, 0),
           String(cString: result) == "ok" { return }
        throw GTFSStoreError.integrityFailed("integrity_check returned non-ok")
    }

    private func warmCaches() throws {
        // Routes
        let routeSQL = "SELECT route_id, route_short_name, route_color FROM routes"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, routeSQL, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idC = sqlite3_column_text(stmt, 0),
                      let nameC = sqlite3_column_text(stmt, 1) else { continue }
                let id = String(cString: idC)
                let name = String(cString: nameC)
                let hexColor = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                routeCache[id] = RouteInfo(
                    id: id,
                    shortName: name,
                    color: hexColor.flatMap(colorFromHex),
                    shape: []    // shapes are lazy-loaded when a route is selected
                )
            }
        }

        // Trips (routeId + headsign)
        let tripSQL = "SELECT trip_id, route_id, trip_headsign FROM trips"
        var tripStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, tripSQL, -1, &tripStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(tripStmt) }
            while sqlite3_step(tripStmt) == SQLITE_ROW {
                guard let tidC = sqlite3_column_text(tripStmt, 0),
                      let ridC = sqlite3_column_text(tripStmt, 1) else { continue }
                let tid = String(cString: tidC)
                let rid = String(cString: ridC)
                tripRouteCache[tid] = rid
                if let hsC = sqlite3_column_text(tripStmt, 2) {
                    tripHeadsignCache[tid] = String(cString: hsC)
                }
            }
        }

        // Service calendar (weekly pattern + validity window)
        let calSQL = """
            SELECT service_id, monday, tuesday, wednesday, thursday, friday,
                   saturday, sunday, start_date, end_date
            FROM calendar
        """
        var calStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, calSQL, -1, &calStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(calStmt) }
            while sqlite3_step(calStmt) == SQLITE_ROW {
                guard let sidC = sqlite3_column_text(calStmt, 0) else { continue }
                let sid = String(cString: sidC)
                let days = (1...7).map { sqlite3_column_int(calStmt, Int32($0)) != 0 }
                let start = sqlite3_column_text(calStmt, 8).flatMap { Int(String(cString: $0)) } ?? 0
                let end = sqlite3_column_text(calStmt, 9).flatMap { Int(String(cString: $0)) } ?? 99_999_999
                serviceRules[sid] = ServiceRule(days: days, startInt: start, endInt: end)
                hasCalendarData = true
            }
        }

        // Calendar exceptions (service added/removed on specific dates)
        let cdSQL = "SELECT service_id, date, exception_type FROM calendar_dates"
        var cdStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, cdSQL, -1, &cdStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(cdStmt) }
            while sqlite3_step(cdStmt) == SQLITE_ROW {
                guard let sidC = sqlite3_column_text(cdStmt, 0),
                      let dateC = sqlite3_column_text(cdStmt, 1),
                      let dateInt = Int(String(cString: dateC)) else { continue }
                let sid = String(cString: sidC)
                serviceExceptions[sid, default: [:]][dateInt] = Int(sqlite3_column_int(cdStmt, 2))
                hasCalendarData = true
            }
        }
    }

    private func firstShapeId(forRoute routeId: String) -> String? {
        let sql = "SELECT shape_id FROM trips WHERE route_id = ? AND shape_id IS NOT NULL LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, routeId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private func shapePoints(shapeId: String) -> [CLLocationCoordinate2D] {
        let sql = """
            SELECT shape_pt_lat, shape_pt_lon
            FROM shapes
            WHERE shape_id = ?
            ORDER BY shape_pt_sequence
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, shapeId, -1, SQLITE_TRANSIENT)

        var points: [CLLocationCoordinate2D] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let lat = sqlite3_column_double(stmt, 0)
            let lon = sqlite3_column_double(stmt, 1)
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            guard coord.isValid else { continue }
            points.append(coord)
        }
        return points
    }

    /// Parses "HH:MM:SS" (hours may exceed 23) → total seconds from midnight.
    private func parseGTFSTime(_ s: String) -> Int? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// Converts a 6-char hex string (e.g. "0066CC") to SwiftUI Color.
    private func colorFromHex(_ hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Errors

enum GTFSStoreError: Error, LocalizedError {
    case cannotOpen(URL)
    case integrityFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let url): return "Cannot open GTFS SQLite at \(url.path)"
        case .integrityFailed(let msg): return "GTFS SQLite integrity check failed: \(msg)"
        }
    }
}

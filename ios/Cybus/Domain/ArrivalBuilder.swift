import Foundation
import CoreLocation

// MARK: - ArrivalBuilder
//
// The primary seam: pure transformations from (static snapshot + decoded feed + query)
// to domain values. No network, no UI, fully testable with fixture data.
//
//   buildVehicles(store:feed:)        → [Vehicle]
//   buildArrivals(store:feed:stopId:now:) → [Arrival]   (soonest-first)
//   resolveVehicle(in:arrival:)        → Vehicle?

enum ArrivalBuilder {

    // MARK: - buildVehicles

    /// Derives [Vehicle] from the VehiclePosition entities in `feed`,
    /// joining to `store` to resolve route metadata.
    ///
    /// Drops any vehicle whose coordinates fail a range check.
    static func buildVehicles(store: any GTFSStoreProtocol, feed: FeedMessage) -> [Vehicle] {
        var seen = Set<String>()        // dedup by vehicleId
        var vehicles: [Vehicle] = []

        for entity in feed.entities {
            guard let vp = entity.vehiclePosition else { continue }

            // Deduplicate (the combined CyNAP feed can repeat entities)
            guard seen.insert(vp.vehicleId).inserted else { continue }

            // Coordinate safety check
            let coord = CLLocationCoordinate2D(
                latitude: Double(vp.latitude),
                longitude: Double(vp.longitude)
            )
            guard coord.isValid else { continue }

            // Resolve route (from VehiclePosition.routeId or via trip join)
            let routeId = vp.routeId
                ?? vp.tripId.flatMap { store.routeId(forTrip: $0) }
                ?? ""
            let route = store.route(id: routeId)

            vehicles.append(Vehicle(
                id: vp.vehicleId,
                tripId: vp.tripId ?? "",
                routeId: routeId,
                routeShortName: route?.shortName ?? routeId,
                routeColor: route?.color,
                coordinate: coord,
                bearing: vp.bearing,
                updatedAt: vp.timestamp ?? feed.timestamp
            ))
        }

        return vehicles
    }

    // MARK: - buildArrivals

    /// Builds a soonest-first list of Arrivals at `stopId`.
    ///
    /// Algorithm:
    ///  1. Collect live predictions from TripUpdate entities that mention `stopId`.
    ///  2. Query the static store for scheduled trips serving `stopId` within the
    ///     next `windowHours` hours.
    ///  3. For any scheduled trip NOT already represented by a live prediction,
    ///     emit a .scheduled Arrival as a fallback.
    ///  4. Drop arrivals already departed (more than 60 s in the past).
    ///  5. Sort by effective arrival time, soonest first.
    static func buildArrivals(
        store: any GTFSStoreProtocol,
        feed: FeedMessage,
        stopId: String,
        now: Date
    ) -> [Arrival] {
        var arrivals: [Arrival] = []
        let cutoffPast = now.addingTimeInterval(-60)    // 60-s grace for departing buses

        // ── 1. Live arrivals ──────────────────────────────────────────────────

        // Build fast lookup: tripId → vehicleId (from VehiclePosition entities)
        let vehicleByTrip: [String: String] = Dictionary(
            uniqueKeysWithValues: feed.entities.compactMap { e -> (String, String)? in
                guard let vp = e.vehiclePosition, let tid = vp.tripId else { return nil }
                return (tid, vp.vehicleId)
            }
        )

        var liveTrips = Set<String>()

        for entity in feed.entities {
            guard let tu = entity.tripUpdate else { continue }

            // Find the StopTimeUpdate for this stop (match by stop_id)
            guard let stu = tu.stopTimeUpdates.first(where: { $0.stopId == stopId }),
                  let event = stu.arrival ?? stu.departure,
                  let arrivalDate = event.time,
                  arrivalDate > cutoffPast
            else { continue }

            // Dedup by tripId — the combined CyNAP feed can repeat entities,
            // which would otherwise produce duplicate live rows for one bus.
            guard liveTrips.insert(tu.tripId).inserted else { continue }

            let routeId = tu.routeId ?? store.routeId(forTrip: tu.tripId) ?? ""
            let route = store.route(id: routeId)
            let countdown = arrivalDate.timeIntervalSince(now)

            arrivals.append(Arrival(
                id: "\(tu.tripId)-\(stopId)-live",
                tripId: tu.tripId,
                routeId: routeId,
                routeShortName: route?.shortName ?? routeId,
                headsign: store.headsign(forTrip: tu.tripId),
                kind: .live(countdown: countdown, vehicleId: vehicleByTrip[tu.tripId])
            ))
        }

        // ── 2 & 3. Scheduled fallback ─────────────────────────────────────────

        let scheduled = store.upcomingTrips(stopId: stopId, after: now)
        for trip in scheduled where !liveTrips.contains(trip.tripId) {
            guard trip.arrivalTime > cutoffPast else { continue }
            let route = store.route(id: trip.routeId)
            arrivals.append(Arrival(
                id: "\(trip.tripId)-\(stopId)-sched",
                tripId: trip.tripId,
                routeId: trip.routeId,
                routeShortName: route?.shortName ?? trip.routeId,
                headsign: store.headsign(forTrip: trip.tripId),
                kind: .scheduled(clockTime: trip.arrivalTime)
            ))
        }

        // ── 4 & 5. Sort ───────────────────────────────────────────────────────

        return arrivals.sorted { $0.absoluteTime(relativeTo: now) < $1.absoluteTime(relativeTo: now) }
    }

    // MARK: - resolveVehicle

    /// Finds the Vehicle on the map that corresponds to a given Arrival.
    ///
    /// For live Arrivals, matches by tripId (the stable join key in GTFS-RT).
    /// Returns nil for scheduled Arrivals (no live Vehicle yet), which the UI
    /// handles by drawing the Route line only.
    static func resolveVehicle(in vehicles: [Vehicle], for arrival: Arrival) -> Vehicle? {
        guard arrival.isLive else { return nil }
        // Primary: match by tripId
        return vehicles.first { $0.tripId == arrival.tripId }
    }
}

// MARK: - Formatting helpers (UI convenience, kept near the builder)

extension Arrival {
    /// Display string for the arrival time.
    /// - ≤ 59 min: "5 min" (or "Due" / "Now" when ≤ 0)
    /// - > 59 min: "14:35"
    func formattedTime(relativeTo now: Date) -> String {
        switch kind {
        case .live(let countdown, _):
            if countdown <= 0 { return "Due" }
            let minutes = Int(countdown / 60)
            if minutes == 0 { return "Due" }
            if minutes < 60 { return "\(minutes) min" }
            return clockFormatted(absoluteTime(relativeTo: now))

        case .scheduled(let clockTime):
            let delta = clockTime.timeIntervalSince(now)
            if delta < 0 { return clockFormatted(clockTime) }
            let minutes = Int(delta / 60)
            if minutes < 60 { return "\(minutes) min" }
            return clockFormatted(clockTime)
        }
    }

    private func clockFormatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

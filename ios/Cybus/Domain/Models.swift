import CoreLocation
import SwiftUI

// MARK: - Vehicle

/// A single physical bus currently in service, visible on the map.
struct Vehicle: Identifiable, Equatable {
    let id: String                  // vehicle_id from VehiclePosition entity
    let tripId: String
    let routeId: String
    let routeShortName: String
    let routeColor: Color?
    let coordinate: CLLocationCoordinate2D
    let bearing: Float?             // degrees, 0 = north, nil if unknown
    let updatedAt: Date

    static func == (lhs: Vehicle, rhs: Vehicle) -> Bool {
        lhs.id == rhs.id
            && lhs.tripId == rhs.tripId
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.bearing == rhs.bearing
    }
}

// MARK: - Stop

/// A fixed boarding point with a name and location.
struct Stop: Identifiable {
    let id: String                  // stop_id
    let name: String
    let coordinate: CLLocationCoordinate2D
}

// MARK: - RouteInfo

/// Static metadata for a named bus line, including the polyline used when selected.
struct RouteInfo: Identifiable {
    let id: String                  // route_id
    let shortName: String
    let color: Color?
    let shape: [CLLocationCoordinate2D]  // ordered points for drawing the route polyline
}

// MARK: - Arrival

/// When a Vehicle is expected at a Stop.
enum ArrivalKind {
    /// Live prediction from GTFS-RT TripUpdates.
    case live(countdown: TimeInterval, vehicleId: String?)
    /// Scheduled time from static GTFS; no real-time data for this Trip.
    case scheduled(clockTime: Date)
}

struct Arrival: Identifiable {
    let id: String                  // stable: "\(tripId)-\(stopId)-\(source)"
    let tripId: String
    let routeId: String
    let routeShortName: String
    let headsign: String?
    let kind: ArrivalKind

    var isLive: Bool {
        if case .live = kind { return true }
        return false
    }

    /// Absolute wall-clock arrival time (computed for both live and scheduled).
    func absoluteTime(relativeTo now: Date) -> Date {
        switch kind {
        case .live(let countdown, _):
            return now.addingTimeInterval(countdown)
        case .scheduled(let clockTime):
            return clockTime
        }
    }
}

// MARK: - ScheduledTrip (internal helper for GTFSStore output)

/// A trip that serves a given stop at a known scheduled time.
struct ScheduledTrip {
    let tripId: String
    let routeId: String
    let arrivalTime: Date           // resolved to today's calendar date
}

// MARK: - Coordinate validation

extension CLLocationCoordinate2D {
    /// True only when the coordinate is a plausible real-world location.
    var isValid: Bool {
        CLLocationCoordinate2DIsValid(self)
            && abs(latitude) <= 90
            && abs(longitude) <= 180
            && !(latitude == 0 && longitude == 0) // explicit null-island guard
    }
}

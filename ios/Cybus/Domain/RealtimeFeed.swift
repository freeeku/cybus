import Foundation
import SwiftProtobuf

// MARK: - GTFS-RT decoded types
//
// These are clean Swift value types representing the relevant subset of the
// GTFS-RT FeedMessage protobuf (gtfs_realtime_version "2.0"). The actual
// decoding from binary protobuf is performed by FeedDecoder (backed by the
// SwiftProtobuf + GTFS-RT generated code); everything above that seam works
// only with these types.

struct FeedMessage {
    let timestamp: Date
    let entities: [FeedEntity]
}

struct FeedEntity {
    let id: String
    let tripUpdate: TripUpdate?
    let vehiclePosition: VehiclePosition?
}

// MARK: - TripUpdate

struct TripUpdate {
    let tripId: String
    let routeId: String?            // may be absent; join via static SQLite if nil
    let stopTimeUpdates: [StopTimeUpdate]
}

struct StopTimeUpdate {
    let stopSequence: Int?
    let stopId: String?
    let arrival: StopTimeEvent?
    let departure: StopTimeEvent?
}

struct StopTimeEvent {
    let time: Date?                 // absolute wall-clock time (unix timestamp → Date)
    let delay: Int?                 // seconds of delay; nil if not provided
}

// MARK: - VehiclePosition

struct VehiclePosition {
    let vehicleId: String
    let tripId: String?
    let routeId: String?
    let latitude: Float
    let longitude: Float
    let bearing: Float?
    let timestamp: Date?
}

// MARK: - FeedDecoder

/// Decodes the binary GTFS-RT protobuf blob served by the Cloudflare proxy.
/// Backed by SwiftProtobuf + the generated code in `Generated/gtfs-realtime.pb.swift`
/// (regenerate with `ios/gtfs-rt/generate.sh`); the proto types stay isolated
/// here so the rest of the domain layer is independent of the proto library.
enum FeedDecoder {
    enum Error: Swift.Error {
        case emptyData
        case exceedsMaxSize(bytes: Int)
        case decodingFailed(underlying: Swift.Error)
    }

    /// Maximum accepted payload size (5 MB). Rejects oversized or hostile feeds
    /// before passing them to the protobuf parser.
    static let maxBytes = 5 * 1_024 * 1_024

    static func decode(_ data: Data) throws -> FeedMessage {
        guard !data.isEmpty else { throw Error.emptyData }
        guard data.count <= maxBytes else { throw Error.exceedsMaxSize(bytes: data.count) }

        let proto: TransitRealtime_FeedMessage
        do {
            proto = try TransitRealtime_FeedMessage(serializedBytes: data)
        } catch {
            throw Error.decodingFailed(underlying: error)
        }
        return FeedMessage(proto)
    }
}

// MARK: - Proto → domain mapping
//
// Translates the SwiftProtobuf-generated TransitRealtime_* types into the clean
// domain value types above, reading only the subset of fields the app uses.
// proto2 optional fields are gated on their `has*` accessors so an absent field
// maps to nil/"" rather than a misleading proto default.

private extension FeedMessage {
    init(_ p: TransitRealtime_FeedMessage) {
        let timestamp = (p.hasHeader && p.header.hasTimestamp)
            ? Date(timeIntervalSince1970: TimeInterval(p.header.timestamp))
            : Date()
        self.init(timestamp: timestamp, entities: p.entity.map(FeedEntity.init))
    }
}

private extension FeedEntity {
    init(_ e: TransitRealtime_FeedEntity) {
        self.init(
            id: e.id,
            tripUpdate: e.hasTripUpdate ? TripUpdate(e.tripUpdate) : nil,
            vehiclePosition: e.hasVehicle ? VehiclePosition(e.vehicle) : nil
        )
    }
}

private extension TripUpdate {
    init(_ tu: TransitRealtime_TripUpdate) {
        self.init(
            tripId: tu.trip.tripID,
            routeId: tu.trip.hasRouteID ? tu.trip.routeID : nil,
            stopTimeUpdates: tu.stopTimeUpdate.map(StopTimeUpdate.init)
        )
    }
}

private extension StopTimeUpdate {
    init(_ s: TransitRealtime_TripUpdate.StopTimeUpdate) {
        self.init(
            stopSequence: s.hasStopSequence ? Int(s.stopSequence) : nil,
            stopId: s.hasStopID ? s.stopID : nil,
            arrival: s.hasArrival ? StopTimeEvent(s.arrival) : nil,
            departure: s.hasDeparture ? StopTimeEvent(s.departure) : nil
        )
    }
}

private extension StopTimeEvent {
    init(_ e: TransitRealtime_TripUpdate.StopTimeEvent) {
        self.init(
            time: e.hasTime ? Date(timeIntervalSince1970: TimeInterval(e.time)) : nil,
            delay: e.hasDelay ? Int(e.delay) : nil
        )
    }
}

private extension VehiclePosition {
    init(_ v: TransitRealtime_VehiclePosition) {
        self.init(
            vehicleId: v.hasVehicle ? v.vehicle.id : "",
            tripId: (v.hasTrip && v.trip.hasTripID) ? v.trip.tripID : nil,
            routeId: (v.hasTrip && v.trip.hasRouteID) ? v.trip.routeID : nil,
            latitude: v.hasPosition ? v.position.latitude : 0,
            longitude: v.hasPosition ? v.position.longitude : 0,
            bearing: (v.hasPosition && v.position.hasBearing) ? v.position.bearing : nil,
            timestamp: v.hasTimestamp ? Date(timeIntervalSince1970: TimeInterval(v.timestamp)) : nil
        )
    }
}

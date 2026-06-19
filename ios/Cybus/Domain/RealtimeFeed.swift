import Foundation

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
/// Backed by SwiftProtobuf + the GTFS-RT generated code; isolated here so the
/// rest of the domain layer is fully independent of the proto library.
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

        // TODO: Replace stub with SwiftProtobuf decode once proto-generated code
        // is added to the project (see ios/gtfs-rt/transit_realtime.pb.swift).
        //
        // Real implementation:
        //   let proto = try TransitRealtime_FeedMessage(serializedData: data)
        //   return FeedMessage(from: proto)
        //
        // For now, return an empty feed so the rest of the stack compiles and
        // the app degrades gracefully (shows scheduled-only arrivals).
        let timestamp = Date()
        return FeedMessage(timestamp: timestamp, entities: [])
    }
}

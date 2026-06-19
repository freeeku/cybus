import XCTest
import SwiftProtobuf
@testable import Cybus

/// Exercises the GTFS-RT seam: build a proto FeedMessage, serialize it to the
/// same binary the proxy would serve, decode it, and assert on the domain
/// values out. Network-free; fixtures stand in for the live feed.
final class FeedDecoderTests: XCTestCase {

    /// FeedMessage.header is `required` in the GTFS-RT proto2 schema, as is its
    /// gtfs_realtime_version, so every fixture needs a valid header to serialize.
    private func makeHeader() -> TransitRealtime_FeedHeader {
        var header = TransitRealtime_FeedHeader()
        header.gtfsRealtimeVersion = "2.0"
        header.timestamp = 1_700_000_100
        return header
    }

    // MARK: - Hardening

    func testEmptyDataThrows() {
        XCTAssertThrowsError(try FeedDecoder.decode(Data()))
    }

    func testOversizedDataThrows() {
        let tooBig = Data(count: FeedDecoder.maxBytes + 1)
        XCTAssertThrowsError(try FeedDecoder.decode(tooBig))
    }

    func testGarbageDataThrows() {
        // Random bytes that aren't a valid protobuf.
        let junk = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try FeedDecoder.decode(junk))
    }

    // MARK: - VehiclePosition mapping

    func testDecodesVehiclePosition() throws {
        var position = TransitRealtime_Position()
        position.latitude = 34.9
        position.longitude = 33.0
        position.bearing = 90

        var descriptor = TransitRealtime_VehicleDescriptor()
        descriptor.id = "V1"

        var trip = TransitRealtime_TripDescriptor()
        trip.tripID = "T1"
        trip.routeID = "R1"

        var vp = TransitRealtime_VehiclePosition()
        vp.vehicle = descriptor
        vp.trip = trip
        vp.position = position
        vp.timestamp = 1_700_000_000

        var entity = TransitRealtime_FeedEntity()
        entity.id = "e1"
        entity.vehicle = vp

        var msg = TransitRealtime_FeedMessage()
        msg.header = makeHeader()
        msg.entity = [entity]

        let data: Data = try msg.serializedBytes()
        let feed = try FeedDecoder.decode(data)

        XCTAssertEqual(feed.timestamp, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(feed.entities.count, 1)

        let decoded = try XCTUnwrap(feed.entities[0].vehiclePosition)
        XCTAssertEqual(decoded.vehicleId, "V1")
        XCTAssertEqual(decoded.tripId, "T1")
        XCTAssertEqual(decoded.routeId, "R1")
        XCTAssertEqual(decoded.latitude, 34.9, accuracy: 0.0001)
        XCTAssertEqual(decoded.longitude, 33.0, accuracy: 0.0001)
        XCTAssertEqual(decoded.bearing, 90)
        XCTAssertEqual(decoded.timestamp, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(feed.entities[0].tripUpdate)
    }

    /// Absent optional sub-fields must map to nil, not proto defaults.
    func testVehiclePositionWithoutOptionalsMapsToNil() throws {
        var position = TransitRealtime_Position()
        position.latitude = 35.0
        position.longitude = 33.3

        var descriptor = TransitRealtime_VehicleDescriptor()
        descriptor.id = "V2"

        var vp = TransitRealtime_VehiclePosition()
        vp.vehicle = descriptor
        vp.position = position           // no trip, no bearing, no timestamp

        var entity = TransitRealtime_FeedEntity()
        entity.id = "e2"
        entity.vehicle = vp

        var msg = TransitRealtime_FeedMessage()
        msg.header = makeHeader()
        msg.entity = [entity]

        let feed = try FeedDecoder.decode(try msg.serializedBytes())
        let decoded = try XCTUnwrap(feed.entities[0].vehiclePosition)
        XCTAssertEqual(decoded.vehicleId, "V2")
        XCTAssertNil(decoded.tripId)
        XCTAssertNil(decoded.routeId)
        XCTAssertNil(decoded.bearing)
        XCTAssertNil(decoded.timestamp)
    }

    // MARK: - TripUpdate mapping

    func testDecodesTripUpdate() throws {
        var arrival = TransitRealtime_TripUpdate.StopTimeEvent()
        arrival.time = 1_700_000_500

        var stu = TransitRealtime_TripUpdate.StopTimeUpdate()
        stu.stopID = "S1"
        stu.stopSequence = 3
        stu.arrival = arrival

        var trip = TransitRealtime_TripDescriptor()
        trip.tripID = "T2"               // no routeID

        var tu = TransitRealtime_TripUpdate()
        tu.trip = trip
        tu.stopTimeUpdate = [stu]

        var entity = TransitRealtime_FeedEntity()
        entity.id = "e3"
        entity.tripUpdate = tu

        var msg = TransitRealtime_FeedMessage()
        msg.header = makeHeader()
        msg.entity = [entity]

        let feed = try FeedDecoder.decode(try msg.serializedBytes())

        let decoded = try XCTUnwrap(feed.entities[0].tripUpdate)
        XCTAssertEqual(decoded.tripId, "T2")
        XCTAssertNil(decoded.routeId)
        XCTAssertEqual(decoded.stopTimeUpdates.count, 1)
        XCTAssertEqual(decoded.stopTimeUpdates[0].stopId, "S1")
        XCTAssertEqual(decoded.stopTimeUpdates[0].stopSequence, 3)
        XCTAssertEqual(
            decoded.stopTimeUpdates[0].arrival?.time,
            Date(timeIntervalSince1970: 1_700_000_500)
        )
        XCTAssertNil(feed.entities[0].vehiclePosition)
    }

    // MARK: - Empty feed (night-time)

    func testEmptyFeedDecodesToNoEntities() throws {
        var msg = TransitRealtime_FeedMessage()
        msg.header = makeHeader()

        let feed = try FeedDecoder.decode(try msg.serializedBytes())
        XCTAssertTrue(feed.entities.isEmpty)
    }
}

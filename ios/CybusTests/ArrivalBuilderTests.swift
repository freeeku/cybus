import XCTest
import CoreLocation
@testable import Cybus

// MARK: - Fixture helpers

private let refDate = ISO8601DateFormatter().date(from: "2026-06-18T10:00:00Z")!

/// A lightweight mock that satisfies GTFSStoreProtocol using in-memory dictionaries.
private final class MockGTFSStore: GTFSStoreProtocol {
    var routes: [String: RouteInfo] = [:]
    var tripRoutes: [String: String] = [:]
    var tripHeadsigns: [String: String] = [:]
    var upcomingTripsByStop: [String: [ScheduledTrip]] = [:]
    var allStops: [Stop] = []

    func route(id: String) -> RouteInfo? { routes[id] }
    func routeId(forTrip tripId: String) -> String? { tripRoutes[tripId] }
    func headsign(forTrip tripId: String) -> String? { tripHeadsigns[tripId] }
    func shape(forRoute routeId: String) -> [CLLocationCoordinate2D] { [] }
    func upcomingTrips(stopId: String, after: Date) -> [ScheduledTrip] {
        upcomingTripsByStop[stopId] ?? []
    }
    func stops(in bounds: CoordinateBounds, limit: Int) -> [Stop] {
        Array(allStops.filter {
            $0.coordinate.latitude >= bounds.minLat && $0.coordinate.latitude <= bounds.maxLat &&
            $0.coordinate.longitude >= bounds.minLon && $0.coordinate.longitude <= bounds.maxLon
        }.prefix(limit))
    }
}

private func makeRoute(_ id: String, shortName: String) -> RouteInfo {
    RouteInfo(id: id, shortName: shortName, color: nil, shape: [])
}

private func makeFeed(
    tripUpdates: [TripUpdate] = [],
    vehiclePositions: [VehiclePosition] = [],
    timestamp: Date = refDate
) -> FeedMessage {
    var entities: [FeedEntity] = []
    for tu in tripUpdates {
        entities.append(FeedEntity(id: tu.tripId, tripUpdate: tu, vehiclePosition: nil))
    }
    for vp in vehiclePositions {
        entities.append(FeedEntity(id: vp.vehicleId, tripUpdate: nil, vehiclePosition: vp))
    }
    return FeedMessage(timestamp: timestamp, entities: entities)
}

private func makeTripUpdate(
    tripId: String,
    routeId: String? = nil,
    stopId: String,
    arrivalOffset: TimeInterval       // seconds from refDate
) -> TripUpdate {
    let arrivalDate = refDate.addingTimeInterval(arrivalOffset)
    let stu = StopTimeUpdate(
        stopSequence: nil,
        stopId: stopId,
        arrival: StopTimeEvent(time: arrivalDate, delay: nil),
        departure: nil
    )
    return TripUpdate(tripId: tripId, routeId: routeId, stopTimeUpdates: [stu])
}

private func makeVehiclePosition(
    vehicleId: String,
    tripId: String,
    lat: Float = 34.9,
    lon: Float = 33.0,
    timestamp: Date? = refDate
) -> VehiclePosition {
    VehiclePosition(
        vehicleId: vehicleId,
        tripId: tripId,
        routeId: nil,
        latitude: lat,
        longitude: lon,
        bearing: nil,
        timestamp: timestamp
    )
}

// MARK: - buildVehicles tests

final class BuildVehiclesTests: XCTestCase {

    func testVehiclesBuiltFromPositions() {
        let store = MockGTFSStore()
        store.routes["R1"] = makeRoute("R1", shortName: "30")
        store.tripRoutes["T1"] = "R1"

        let vp = makeVehiclePosition(vehicleId: "V1", tripId: "T1")
        let feed = makeFeed(vehiclePositions: [vp])

        let vehicles = ArrivalBuilder.buildVehicles(store: store, feed: feed, now: refDate)

        XCTAssertEqual(vehicles.count, 1)
        XCTAssertEqual(vehicles[0].id, "V1")
        XCTAssertEqual(vehicles[0].tripId, "T1")
        XCTAssertEqual(vehicles[0].routeShortName, "30")
    }

    func testDuplicateVehiclesDeduped() {
        let store = MockGTFSStore()
        let vp1 = makeVehiclePosition(vehicleId: "V1", tripId: "T1")
        let vp2 = makeVehiclePosition(vehicleId: "V1", tripId: "T1")   // duplicate
        let feed = makeFeed(vehiclePositions: [vp1, vp2])

        let vehicles = ArrivalBuilder.buildVehicles(store: store, feed: feed, now: refDate)
        XCTAssertEqual(vehicles.count, 1)
    }

    func testOutOfRangeCoordinateDropped() {
        let store = MockGTFSStore()
        // Null island (0, 0) and invalid lat
        let bad1 = makeVehiclePosition(vehicleId: "V1", tripId: "T1", lat: 0, lon: 0)
        let bad2 = makeVehiclePosition(vehicleId: "V2", tripId: "T2", lat: 999, lon: 33)
        let feed = makeFeed(vehiclePositions: [bad1, bad2])

        let vehicles = ArrivalBuilder.buildVehicles(store: store, feed: feed, now: refDate)
        XCTAssertEqual(vehicles.count, 0)
    }

    func testEmptyFeedProducesNoVehicles() {
        let store = MockGTFSStore()
        let vehicles = ArrivalBuilder.buildVehicles(store: store, feed: makeFeed(), now: refDate)
        XCTAssertTrue(vehicles.isEmpty, "Night-time empty feed should yield no vehicles")
    }

    // A bus whose last fix predates the staleness cutoff must be dropped — the
    // CyNAP feed leaves off-shift buses in the feed with a frozen timestamp.
    func testStaleVehicleDropped() {
        let store = MockGTFSStore()
        store.tripRoutes["T1"] = "R1"

        // V1 reported now; V2 reported just past the max age — only V1 survives.
        let fresh = makeVehiclePosition(vehicleId: "V1", tripId: "T1")
        let stale = makeVehiclePosition(
            vehicleId: "V2", tripId: "T2", lat: 34.91, lon: 33.01,
            timestamp: refDate.addingTimeInterval(-(ArrivalBuilder.vehicleMaxAge + 1))
        )

        let feed = makeFeed(vehiclePositions: [fresh, stale])
        let vehicles = ArrivalBuilder.buildVehicles(store: store, feed: feed, now: refDate)

        XCTAssertEqual(vehicles.map(\.id), ["V1"])
    }

    // A vehicle without its own timestamp inherits the feed timestamp, so an
    // actively-published feed keeps it visible (the feed itself proves freshness).
    func testUntimestampedVehicleKeptWhenFeedIsFresh() {
        let store = MockGTFSStore()
        let vp = makeVehiclePosition(vehicleId: "V1", tripId: "T1", timestamp: nil)

        let feed = makeFeed(vehiclePositions: [vp], timestamp: refDate)
        let vehicles = ArrivalBuilder.buildVehicles(store: store, feed: feed, now: refDate)

        XCTAssertEqual(vehicles.count, 1)
    }
}

// MARK: - buildArrivals tests

final class BuildArrivalsTests: XCTestCase {

    func testLiveArrivalFromTripUpdate() {
        let store = MockGTFSStore()
        store.routes["R1"] = makeRoute("R1", shortName: "30")
        store.tripRoutes["T1"] = "R1"

        let tu = makeTripUpdate(tripId: "T1", stopId: "S1", arrivalOffset: 300) // 5 min
        let feed = makeFeed(tripUpdates: [tu])

        let arrivals = ArrivalBuilder.buildArrivals(
            store: store, feed: feed, stopId: "S1", now: refDate
        )

        XCTAssertEqual(arrivals.count, 1)
        XCTAssertTrue(arrivals[0].isLive)
        XCTAssertEqual(arrivals[0].routeShortName, "30")
        if case .live(let countdown, _) = arrivals[0].kind {
            XCTAssertEqual(countdown, 300, accuracy: 1)
        } else {
            XCTFail("Expected live arrival")
        }
    }

    func testScheduledFallbackWhenTripNotInFeed() {
        let store = MockGTFSStore()
        store.routes["R2"] = makeRoute("R2", shortName: "10")
        let scheduled = ScheduledTrip(
            tripId: "T2",
            routeId: "R2",
            arrivalTime: refDate.addingTimeInterval(900) // 15 min
        )
        store.upcomingTripsByStop["S1"] = [scheduled]

        let feed = makeFeed()   // no TripUpdates

        let arrivals = ArrivalBuilder.buildArrivals(
            store: store, feed: feed, stopId: "S1", now: refDate
        )

        XCTAssertEqual(arrivals.count, 1)
        XCTAssertFalse(arrivals[0].isLive)
        XCTAssertEqual(arrivals[0].routeShortName, "10")
    }

    func testArrivalsOrderedSoonestFirst() {
        let store = MockGTFSStore()
        store.routes["R1"] = makeRoute("R1", shortName: "30")
        store.tripRoutes["T1"] = "R1"
        store.tripRoutes["T2"] = "R1"

        let tu1 = makeTripUpdate(tripId: "T1", stopId: "S1", arrivalOffset: 600)  // 10 min
        let tu2 = makeTripUpdate(tripId: "T2", stopId: "S1", arrivalOffset: 120)  //  2 min

        let feed = makeFeed(tripUpdates: [tu1, tu2])

        let arrivals = ArrivalBuilder.buildArrivals(
            store: store, feed: feed, stopId: "S1", now: refDate
        )

        XCTAssertEqual(arrivals.count, 2)
        // T2 (2 min) should come before T1 (10 min)
        XCTAssertEqual(arrivals[0].tripId, "T2")
        XCTAssertEqual(arrivals[1].tripId, "T1")
    }

    func testScheduledNotDuplicatedWhenLiveFeedHasTrip() {
        let store = MockGTFSStore()
        store.routes["R1"] = makeRoute("R1", shortName: "30")
        store.tripRoutes["T1"] = "R1"

        let tu = makeTripUpdate(tripId: "T1", stopId: "S1", arrivalOffset: 300)

        // Same trip also appears in the scheduled store
        let scheduled = ScheduledTrip(
            tripId: "T1",
            routeId: "R1",
            arrivalTime: refDate.addingTimeInterval(360)
        )
        store.upcomingTripsByStop["S1"] = [scheduled]

        let feed = makeFeed(tripUpdates: [tu])
        let arrivals = ArrivalBuilder.buildArrivals(
            store: store, feed: feed, stopId: "S1", now: refDate
        )

        // Should appear exactly once (live takes precedence)
        XCTAssertEqual(arrivals.count, 1)
        XCTAssertTrue(arrivals[0].isLive)
    }

    // The RT feed strips the "AGENCY:" prefix from stop_ids; the tapped stop is
    // a full static id. Live arrivals must still match.
    func testLiveArrivalMatchesWhenFeedStopIdIsPrefixStripped() {
        let store = MockGTFSStore()
        store.routes["EMEL:R1"] = makeRoute("EMEL:R1", shortName: "30")
        store.tripRoutes["T1"] = "EMEL:R1"

        // Feed reports the bare stop id "55"; user tapped "EMEL:55".
        let tu = makeTripUpdate(tripId: "T1", stopId: "55", arrivalOffset: 300)
        let feed = makeFeed(tripUpdates: [tu])

        let arrivals = ArrivalBuilder.buildArrivals(
            store: store, feed: feed, stopId: "EMEL:55", now: refDate
        )

        XCTAssertEqual(arrivals.count, 1)
        XCTAssertTrue(arrivals[0].isLive)
        XCTAssertEqual(arrivals[0].routeShortName, "30")
    }

    // Bare stop numbers are reused across operators. A trip from a different
    // agency that references the same bare number must not surface at this stop.
    func testLiveArrivalRejectedWhenTripAgencyDiffersFromStop() {
        let store = MockGTFSStore()
        store.routes["Intercity:R9"] = makeRoute("Intercity:R9", shortName: "36")
        store.tripRoutes["T9"] = "Intercity:R9"

        // Intercity bus references bare stop "55"; user tapped EMEL's stop 55.
        let tu = makeTripUpdate(tripId: "T9", stopId: "55", arrivalOffset: 120)
        let feed = makeFeed(tripUpdates: [tu])

        let arrivals = ArrivalBuilder.buildArrivals(
            store: store, feed: feed, stopId: "EMEL:55", now: refDate
        )

        XCTAssertTrue(arrivals.isEmpty, "A different operator's stop 55 must not appear at EMEL:55")
    }

    // The scheduled store yields prefixed trip ids; the live feed yields bare
    // ones. Dedup must compare on the bare id so a live trip isn't also shown
    // as scheduled.
    func testScheduledNotDuplicatedAcrossPrefixForLiveTrip() {
        let store = MockGTFSStore()
        store.routes["EMEL:R1"] = makeRoute("EMEL:R1", shortName: "30")
        store.tripRoutes["T1"] = "EMEL:R1"

        let tu = makeTripUpdate(tripId: "T1", stopId: "55", arrivalOffset: 300)
        store.upcomingTripsByStop["EMEL:55"] = [
            ScheduledTrip(tripId: "EMEL:T1", routeId: "EMEL:R1",
                          arrivalTime: refDate.addingTimeInterval(360))
        ]

        let feed = makeFeed(tripUpdates: [tu])
        let arrivals = ArrivalBuilder.buildArrivals(
            store: store, feed: feed, stopId: "EMEL:55", now: refDate
        )

        XCTAssertEqual(arrivals.count, 1, "Live trip must not be duplicated by its scheduled twin")
        XCTAssertTrue(arrivals[0].isLive)
    }

    func testAlreadyDepartedArrivalDropped() {
        let store = MockGTFSStore()
        store.tripRoutes["T1"] = "R1"

        // Departure was 5 minutes ago
        let tu = makeTripUpdate(tripId: "T1", stopId: "S1", arrivalOffset: -300)
        let feed = makeFeed(tripUpdates: [tu])

        let arrivals = ArrivalBuilder.buildArrivals(
            store: store, feed: feed, stopId: "S1", now: refDate
        )
        XCTAssertTrue(arrivals.isEmpty)
    }

    func testEmptyFeedAndNoScheduledProducesNoBoardRows() {
        let store = MockGTFSStore()
        let arrivals = ArrivalBuilder.buildArrivals(
            store: store, feed: makeFeed(), stopId: "S1", now: refDate
        )
        XCTAssertTrue(arrivals.isEmpty, "Night-time empty stop board should be empty")
    }
}

// MARK: - resolveVehicle tests

final class ResolveVehicleTests: XCTestCase {

    private func makeLiveArrival(tripId: String, vehicleId: String?) -> Arrival {
        Arrival(
            id: "\(tripId)-S1-live",
            tripId: tripId,
            routeId: "R1",
            routeShortName: "30",
            headsign: nil,
            kind: .live(countdown: 300, vehicleId: vehicleId)
        )
    }

    private func makeScheduledArrival(tripId: String) -> Arrival {
        Arrival(
            id: "\(tripId)-S1-sched",
            tripId: tripId,
            routeId: "R1",
            routeShortName: "30",
            headsign: nil,
            kind: .scheduled(clockTime: refDate.addingTimeInterval(900))
        )
    }

    func testResolvesVehicleByTripId() {
        let vehicle = Vehicle(
            id: "V1", tripId: "T1", routeId: "R1", routeShortName: "30",
            routeColor: nil,
            coordinate: CLLocationCoordinate2D(latitude: 34.9, longitude: 33.0),
            bearing: nil, updatedAt: refDate
        )
        let arrival = makeLiveArrival(tripId: "T1", vehicleId: "V1")
        let resolved = ArrivalBuilder.resolveVehicle(in: [vehicle], for: arrival)
        XCTAssertEqual(resolved?.id, "V1")
    }

    func testReturnsNilWhenVehicleNotInFeed() {
        let arrival = makeLiveArrival(tripId: "T99", vehicleId: nil)
        let resolved = ArrivalBuilder.resolveVehicle(in: [], for: arrival)
        XCTAssertNil(resolved)
    }

    func testReturnsNilForScheduledArrival() {
        let vehicle = Vehicle(
            id: "V1", tripId: "T1", routeId: "R1", routeShortName: "30",
            routeColor: nil,
            coordinate: CLLocationCoordinate2D(latitude: 34.9, longitude: 33.0),
            bearing: nil, updatedAt: refDate
        )
        let arrival = makeScheduledArrival(tripId: "T1")
        let resolved = ArrivalBuilder.resolveVehicle(in: [vehicle], for: arrival)
        XCTAssertNil(resolved, "Scheduled arrivals have no correlated vehicle")
    }
}

// MARK: - formattedTime tests

final class FormattedTimeTests: XCTestCase {

    func testDueWhenCountdownZeroOrNegative() {
        let a = Arrival(id: "x", tripId: "T", routeId: "R", routeShortName: "30",
                        headsign: nil, kind: .live(countdown: 0, vehicleId: nil))
        XCTAssertEqual(a.formattedTime(relativeTo: refDate), "Due")

        let b = Arrival(id: "y", tripId: "T", routeId: "R", routeShortName: "30",
                        headsign: nil, kind: .live(countdown: -30, vehicleId: nil))
        XCTAssertEqual(b.formattedTime(relativeTo: refDate), "Due")
    }

    func testMinutesShownWhenUnderOneHour() {
        let a = Arrival(id: "x", tripId: "T", routeId: "R", routeShortName: "30",
                        headsign: nil, kind: .live(countdown: 7 * 60, vehicleId: nil))
        XCTAssertEqual(a.formattedTime(relativeTo: refDate), "7 min")
    }

    func testClockTimeShownWhenOverOneHour() {
        // 90 minutes from refDate (10:00 UTC) = 11:30 UTC
        let a = Arrival(id: "x", tripId: "T", routeId: "R", routeShortName: "30",
                        headsign: nil, kind: .live(countdown: 90 * 60, vehicleId: nil))
        let formatted = a.formattedTime(relativeTo: refDate)
        XCTAssertTrue(formatted.contains(":"), "Expected clock format for >60 min, got \(formatted)")
    }
}

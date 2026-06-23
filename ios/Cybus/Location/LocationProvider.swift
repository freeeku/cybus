import CoreLocation
import Observation

// MARK: - UserLocation
//
// A small Equatable/Sendable coordinate. CLLocationCoordinate2D is neither, so
// this lets SwiftUI `.onChange(of:)` observe location updates and keeps the
// value safe to hand across the actor hop from the delegate callback.
struct UserLocation: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - LocationProvider
//
// Thin wrapper around CLLocationManager. Requests "when in use" authorization
// and publishes the user's latest coordinate + authorization status for the map
// to observe. This is what makes "buses near me" work: without an authorization
// request, MapKit's user-location button and the blue dot stay inert.
//
// CLLocationManagerDelegate callbacks arrive on an arbitrary thread, so they are
// `nonisolated`; each one extracts only Sendable values (Doubles, the status
// enum) before hopping to the main actor to mutate observable state.

@MainActor
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {

    /// Current authorization status — drives prompt vs. denied UI.
    private(set) var authorizationStatus: CLAuthorizationStatus

    /// Most recent user location, or nil until the first fix arrives.
    private(set) var userLocation: UserLocation?

    private let manager = CLLocationManager()

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    /// Prompt for permission the first time. Once the user has decided, this
    /// just refreshes the fix when already authorized, and is a no-op if denied.
    func requestAuthorization() {
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if self.isAuthorized { self.manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        Task { @MainActor in
            self.userLocation = UserLocation(latitude: lat, longitude: lon)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient (e.g. no fix yet) — keep the current region; the next update
        // will deliver a coordinate. Nothing to surface to the user.
    }
}

import SwiftUI
import MapKit

struct CybusMapView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(LocationProvider.self) private var location
    @State private var position: MapCameraPosition = .automatic
    @State private var didAutoCenter = false       // first auto-center this launch
    @State private var pendingRecenter = false     // user tapped locate; center on next fix

    var body: some View {
        Map(position: $position, interactionModes: .all) {

            // ── User's location (blue dot; visible once authorized) ──────
            UserAnnotation()

            // ── Vehicle markers ──────────────────────────────────────────
            ForEach(appModel.vehicles) { vehicle in
                Annotation("", coordinate: vehicle.coordinate) {
                    VehicleAnnotationView(
                        vehicle: vehicle,
                        isTracked: appModel.trackedVehicle?.id == vehicle.id
                    )
                    .onTapGesture { appModel.selectVehicle(vehicle) }
                }
                .annotationTitles(.hidden)
            }

            // ── Stop pins ────────────────────────────────────────────────
            // AppModel only populates `stops` when zoomed in past the
            // threshold, so this is empty (clean map) when zoomed out.
            ForEach(appModel.stops) { stop in
                Annotation(stop.name, coordinate: stop.coordinate) {
                    StopAnnotationView(
                        stop: stop,
                        isSelected: appModel.selectedStop?.id == stop.id
                    )
                    .onTapGesture { appModel.selectStop(stop) }
                }
                .annotationTitles(.hidden)
            }

            // ── Route polyline (only when a stop/vehicle is selected) ────
            // Drawn as a white casing under a thicker route-colored line so the
            // selected bus's route stands out against the map's own roads.
            if let vehicle = appModel.trackedVehicle,
               let shape = appModel.routeShape(forRoute: vehicle.routeId),
               !shape.isEmpty {
                MapPolyline(coordinates: shape)
                    .stroke(.white, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: shape)
                    .stroke(vehicle.routeColor ?? .blue,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excluding([.publicTransport])))
        // Deliberately NOT MapUserLocationButton: it puts the map into "follow"
        // mode, which locks the camera to the user and fights panning. We use a
        // plain button that recenters once, leaving the map free to scroll.
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .topTrailing) { locateButton }
        .onMapCameraChange(frequency: .onEnd) { context in
            appModel.saveRegion(context.region)
            appModel.updateVisibleStops(for: context.region)
        }
        .onAppear {
            position = .region(appModel.mapRegion)
            location.requestAuthorization()
            // Seed from any fix that already landed before this observer was
            // registered: onChange only fires on a *change*, so without this the
            // first launch never auto-centers when the GPS fix beats the view.
            handleLocationUpdate(location.userLocation?.coordinate)
        }
        .onChange(of: location.userLocation) { _, loc in
            handleLocationUpdate(loc?.coordinate)
        }
        .onChange(of: appModel.trackedVehicle) { _, tracked in
            if let tracked {
                withAnimation(.easeInOut(duration: 0.4)) {
                    position = .camera(MapCamera(
                        centerCoordinate: tracked.coordinate,
                        distance: 3000
                    ))
                }
            }
        }
    }

    // MARK: - Locate button

    /// One-shot "center on me" button (replaces MapUserLocationButton so the map
    /// stays free to pan). Tapping it jumps to the last known location right away
    /// and refreshes for a newer fix.
    private var locateButton: some View {
        Button(action: recenterOnUser) {
            Image(systemName: "location.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .padding(.top, 56)
        .padding(.trailing, 12)
        .accessibilityLabel("Center on my location")
    }

    // MARK: - Centering

    /// Handles each new location fix: auto-center once per launch when the user
    /// is on the island, and honor a pending manual "locate me" tap.
    private func handleLocationUpdate(_ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else { return }
        if !didAutoCenter, AppModel.isInCyprus(coordinate) {
            didAutoCenter = true
            centerOn(coordinate)
        } else if pendingRecenter {
            pendingRecenter = false
            centerOn(coordinate)
        }
    }

    /// Invoked by the locate button. Prompts for permission if needed, jumps to
    /// the last known fix immediately, and asks for a fresh one.
    private func recenterOnUser() {
        location.requestAuthorization()   // prompts if undecided; refreshes the fix if authorized
        if let coordinate = location.userLocation?.coordinate {
            centerOn(coordinate)
        }
        pendingRecenter = true            // re-center when the fresh fix lands
    }

    /// Animates the camera to `coordinate`, zoomed tight enough that nearby Stops
    /// appear (under stopZoomThreshold) while keeping the pin count small.
    /// Also refreshes the visible Stops directly: `onMapCameraChange(.onEnd)` does
    /// not reliably fire for programmatic moves, so we can't rely on it here.
    private func centerOn(_ coordinate: CLLocationCoordinate2D) {
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
        )
        withAnimation(.easeInOut(duration: 0.4)) {
            position = .region(region)
        }
        appModel.saveRegion(region)
        appModel.updateVisibleStops(for: region)
    }
}

// MARK: - VehicleAnnotationView

struct VehicleAnnotationView: View {
    let vehicle: Vehicle
    let isTracked: Bool

    private var size: CGFloat { isTracked ? 34 : 28 }

    var body: some View {
        // Deliberately a rounded SQUARE with a white border and a bus glyph, so a
        // vehicle reads instantly differently from the small hollow round Stop pin.
        // A small heading arrow rides outside the badge to show travel direction
        // without competing with the bus icon.
        ZStack {
            if let bearing = vehicle.bearing {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(vehicle.routeColor ?? .blue)
                    .offset(y: -(size / 2) - 3)
                    .rotationEffect(.degrees(Double(bearing)))
            }

            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(vehicle.routeColor ?? .blue)
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.white, lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)

            Image(systemName: "bus.fill")
                .font(.system(size: isTracked ? 16 : 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .animation(.spring(response: 0.3), value: isTracked)
    }
}

// MARK: - Stop annotation (for future use)

struct StopAnnotationView: View {
    let stop: Stop
    let isSelected: Bool

    var body: some View {
        // No drop shadow: with dozens of stop annotations on screen, per-pin
        // shadows force offscreen rendering and stutter pan/zoom. A solid stroke
        // gives enough contrast against the map.
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : .white)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
        }
    }
}

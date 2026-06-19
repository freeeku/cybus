import SwiftUI
import MapKit

struct CybusMapView: View {
    @Environment(AppModel.self) private var appModel
    @State private var position: MapCameraPosition = .automatic
    @State private var locationManager = CLLocationManager()

    // Zoom threshold (span delta) below which Stop pins appear
    private static let stopZoomThreshold: Double = 0.08

    private var showStops: Bool {
        if case .region(let region) = position {
            return region.span.latitudeDelta < Self.stopZoomThreshold
        }
        return false
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {

                // ── Vehicle markers ──────────────────────────────────────────
                ForEach(appModel.vehicles) { vehicle in
                    Annotation("", coordinate: vehicle.coordinate) {
                        VehicleAnnotationView(
                            vehicle: vehicle,
                            isTracked: appModel.trackedVehicle?.id == vehicle.id
                        )
                    }
                    .annotationTitles(.hidden)
                }

                // ── Stop pins (zoom-dependent) ───────────────────────────────
                if showStops {
                    // Stops are loaded from the GTFSStore on-demand; for now
                    // StopAnnotations are driven by the map region query.
                    // TODO: inject visible stops from AppModel (region query)
                }

                // ── Route polyline (only when a stop/vehicle is selected) ────
                if let vehicle = appModel.trackedVehicle,
                   let shape = appModel.routeShape(forRoute: vehicle.routeId),
                   !shape.isEmpty {
                    MapPolyline(coordinates: shape)
                        .stroke(vehicle.routeColor ?? .blue, lineWidth: 3)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excluding([.publicTransport])))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                appModel.saveRegion(context.region)
            }
            .onAppear {
                position = .region(appModel.mapRegion)
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
    }
}

// MARK: - VehicleAnnotationView

struct VehicleAnnotationView: View {
    let vehicle: Vehicle
    let isTracked: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(vehicle.routeColor ?? .blue)
                .frame(width: isTracked ? 32 : 24, height: isTracked ? 32 : 24)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)

            if let bearing = vehicle.bearing {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(Double(bearing)))
            } else {
                Image(systemName: "bus.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
            }
        }
        .animation(.spring(response: 0.3), value: isTracked)
    }
}

// MARK: - Stop annotation (for future use)

struct StopAnnotationView: View {
    let stop: Stop
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : .white)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                .shadow(color: .black.opacity(0.2), radius: 1)
        }
    }
}

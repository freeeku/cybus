import SwiftUI
import MapKit

struct CybusMapView: View {
    @Environment(AppModel.self) private var appModel
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
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
            appModel.updateVisibleStops(for: context.region)
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

import SwiftUI

/// Detail sheet for a bus tapped on the map. Mirrors StopSheetView's structure
/// (NavigationStack + Done button) so the two read consistently. Shows the
/// route, destination, and how fresh the live position is.
struct VehicleSheetView: View {
    let vehicle: Vehicle
    @Environment(AppModel.self) private var appModel

    // Re-renders the "updated N seconds ago" line so it stays honest while open.
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    private var headsign: String? { appModel.headsign(forTrip: vehicle.tripId) }
    private var routeColor: Color { vehicle.routeColor ?? .accentColor }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Text(vehicle.routeShortName)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(minWidth: 40)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(routeColor))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(headsign ?? "Route \(vehicle.routeShortName)")
                                .font(.headline)
                                .lineLimit(2)
                            liveLabel
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    LabeledContent("Last update", value: updatedText)
                    if let bearing = vehicle.bearing {
                        LabeledContent("Heading", value: compass(from: bearing))
                    }
                    LabeledContent("Vehicle", value: vehicle.id)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Bus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { appModel.dismissVehicle() }
                }
            }
        }
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Sub-components

    private var liveLabel: some View {
        HStack(spacing: 4) {
            Circle().fill(.green).frame(width: 6, height: 6)
            Text("Live")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private var updatedText: String {
        let secondsAgo = max(0, Int(now.timeIntervalSince(vehicle.updatedAt)))
        if secondsAgo < 5 { return "just now" }
        if secondsAgo < 60 { return "\(secondsAgo)s ago" }
        return "\(secondsAgo / 60)m ago"
    }

    /// 0° = north; turns a GTFS-RT bearing into an 8-point compass label.
    private func compass(from bearing: Float) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let idx = Int((bearing.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 45 + 0.5) % 8
        return points[idx]
    }
}

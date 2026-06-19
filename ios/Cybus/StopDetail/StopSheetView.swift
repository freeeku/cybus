import SwiftUI

struct StopSheetView: View {
    let stop: Stop
    @Environment(AppModel.self) private var appModel

    // Auto-refresh while the sheet is open
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                if appModel.arrivals.isEmpty {
                    ContentUnavailableView(
                        "No upcoming arrivals",
                        systemImage: "bus",
                        description: Text("Either no buses are due at this stop in the next 3 hours, or service isn't running right now.")
                    )
                } else {
                    List(appModel.arrivals) { arrival in
                        ArrivalRowView(arrival: arrival, now: Date())
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .onTapGesture { appModel.trackArrival(arrival) }
                            .listRowBackground(
                                appModel.trackedVehicle?.tripId == arrival.tripId
                                    ? Color.accentColor.opacity(0.08)
                                    : Color.clear
                            )
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(stop.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { appModel.dismissStop() }
                }
            }
        }
        .onReceive(refreshTimer) { _ in
            // Re-compute arrivals against a fresh `now`, but preserve the
            // user's tracked vehicle (selectStop would clear it).
            appModel.refreshArrivals()
        }
    }
}

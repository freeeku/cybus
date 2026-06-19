import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        // Bridge selectedStop to the sheet so that *any* dismissal (Done button
        // or swipe-down) routes through dismissStop() and clears stale arrivals
        // and the tracked vehicle.
        let stopBinding = Binding<Stop?>(
            get: { appModel.selectedStop },
            set: { if $0 == nil { appModel.dismissStop() } }
        )

        ZStack(alignment: .bottom) {
            CybusMapView()

            if appModel.isLoadingStatic {
                ProgressView("Loading transit data…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 40)
            }

            if let errorMsg = appModel.staticError {
                Text(errorMsg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 40)
            }
        }
        .sheet(item: stopBinding) { stop in
            StopSheetView(stop: stop)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            appModel.didEnterForeground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            appModel.didEnterBackground()
        }
    }
}

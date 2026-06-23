import SwiftUI

@main
struct CybusApp: App {
    @State private var appModel = AppModel()
    @State private var location = LocationProvider()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(location)
        }
    }
}

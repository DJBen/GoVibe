import SwiftUI
import GoVibeFeature

@main
struct GoVibeApp: App {
    init() {
        GoVibeBootstrap.configureFirebaseIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

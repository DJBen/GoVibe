import GoVibeFeature
import SwiftUI

@main
struct GoVibeApp: App {
    @UIApplicationDelegateAdaptor(GoVibeAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

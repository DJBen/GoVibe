import SwiftUI
import GoVibeHostCore
import AppKit

@main
struct GoVibeHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate
    @State private var manager = HostSessionManager()

    var body: some Scene {
        Window("GoVibe Host", id: "main") {
            HostAppRootView(manager: manager)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("GoVibe Host", systemImage: "desktopcomputer.and.macbook") {
            HostMenuBarView(manager: manager)
        }
    }
}

final class HostAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }

        guard let existing = otherInstances.first else { return }
        existing.activate()
        NSApp.terminate(nil)
    }
}

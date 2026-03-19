import SwiftUI
import GoVibeHostCore
import AppKit
import Observation

@main
struct GoVibeHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate
    @State private var manager = HostSessionManager()
    private var config = HostConfig.shared

    var body: some Scene {
        Window("GoVibe Host", id: "main") {
            Group {
                if config.isValid {
                    HostAppRootView(manager: manager)
                        .frame(minWidth: 980, minHeight: 680)
                        .onAppear {
                            manager.updateFromConfig()
                        }
                } else {
                    HostConfigSetupView()
                        .frame(minWidth: 400, minHeight: 300)
                }
            }
            .onChange(of: config.relayHost) { _, _ in
                manager.updateFromConfig()
            }
        }
        .windowResizability(.contentSize)
        
        Settings {
            HostConfigSetupView()
                .frame(minWidth: 400, minHeight: 300)
        }

        Window("Host ID", id: "host-id") {
            HostIDView(hostId: manager.settings.hostId)
                .frame(minWidth: 360, minHeight: 160)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("GoVibe Host", systemImage: "desktopcomputer.and.macbook") {
            HostMenuBarView(manager: manager)
            Divider()
            ConfigureRelayButton()
            Divider()
            Button("Quit GoVibe Host") {
                NSApp.terminate(nil)
            }
        }
    }
}

private struct ConfigureRelayButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Configure Relay...") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the app running in the tray even when all windows are closed
        return false
    }
}

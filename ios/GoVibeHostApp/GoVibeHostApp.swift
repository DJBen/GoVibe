import SwiftUI
import GoVibeHostCore
import AppKit
import Observation

@main
struct GoVibeHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate
    @State private var manager = HostSessionManager()
    @State private var auth = HostAuthController.shared
    private var config = HostConfig.shared

    var body: some Scene {
        Window("GoVibe Host", id: "main") {
            Group {
                if !auth.isAuthenticated {
                    HostSignInView(auth: auth)
                        .frame(minWidth: 440, minHeight: 360)
                } else if config.isValid {
                    HostAppRootView(manager: manager)
                        .frame(minWidth: 980, minHeight: 680)
                        .onAppear {
                            manager.syncAuthScope(userID: auth.currentUser?.uid)
                            syncHostRegistration()
                            manager.updateFromConfig()
                        }
                } else {
                    HostConfigSetupView()
                        .frame(minWidth: 400, minHeight: 300)
                }
            }
            .onChange(of: auth.currentUser?.uid) { _, userID in
                manager.syncAuthScope(userID: userID)
                if userID != nil {
                    manager.updateFromConfig()
                }
                syncHostRegistration()
            }
            .task {
                await auth.restoreSessionIfPossible()
                manager.syncAuthScope(userID: auth.currentUser?.uid)
                syncHostRegistration()
                manager.updateFromConfig()
            }
            .onChange(of: config.relayHost) { _, _ in
                auth.refreshConfig()
                syncHostRegistration()
                manager.updateFromConfig()
            }
        }
        .windowResizability(.contentSize)
        
        Settings {
            HostConfigSetupView()
                .frame(minWidth: 400, minHeight: 300)
        }

        Window("Device ID", id: "host-id") {
            HostIDView(hostId: manager.settings.hostId)
                .frame(minWidth: 360, minHeight: 160)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            HostMenuBarView(manager: manager)
            Divider()
            if auth.isAuthenticated {
                Button("Sign Out") {
                    manager.stopAllSessions()
                    auth.signOut()
                }
                Divider()
            }
            Button("Quit GoVibe Host") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image("HostMenuBarIcon")
                .renderingMode(.template)
        }
    }

    private func syncHostRegistration() {
        auth.startHostRegistration(
            hostId: manager.settings.hostId,
            displayName: Host.current().localizedName ?? "GoVibe Host",
            capabilities: ["terminal", "simulator", "app_window"],
            discoveryVisible: manager.settings.onboardingCompleted && config.isValid
        )
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

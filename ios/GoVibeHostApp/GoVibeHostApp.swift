import SwiftUI
import GoVibeHostCore
import AppKit
import Observation
import Sparkle

@main
struct GoVibeHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate
    @State private var manager = HostSessionManager()
    @State private var auth = HostAuthController.shared
    @State private var updaterModel = CheckForUpdatesModel()
    private var config = HostConfig.shared

    var body: some Scene {
        Window("GoVibe Host", id: "main") {
            Group {
                if !config.isValid {
                    HostMissingConfigView()
                        .frame(minWidth: 440, minHeight: 300)
                } else if !auth.isAuthenticated {
                    HostSignInView(auth: auth)
                        .frame(width: 440)
                } else {
                    HostAppRootView(manager: manager)
                        .frame(minWidth: 980, minHeight: 680)
                        .onAppear {
                            manager.syncAuthScope(userID: auth.currentUser?.uid)
                            syncHostRegistration()
                            manager.updateFromConfig()
                        }
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
        }
        .windowResizability(.contentSize)

        Window("Device ID", id: "host-id") {
            HostIDView(hostId: manager.settings.hostId)
                .frame(minWidth: 360, minHeight: 160)
        }
        .windowResizability(.contentSize)

        Settings {
            HostSettingsView(manager: manager) {
                auth.signOut()
            }
        }

        MenuBarExtra {
            HostMenuBarView(manager: manager)
            Divider()
            Button("Check for Updates…") {
                updaterModel.updaterController.checkForUpdates(nil)
            }
            .disabled(!updaterModel.canCheckForUpdates)
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

private struct HostMissingConfigView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.orange)

            Text("Configuration Missing")
                .font(.title3.weight(.semibold))

            Text("GoVibe Host requires relay settings provided via build configuration.\nCheck your xcconfig or environment variables.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(24)
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

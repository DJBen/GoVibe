import SwiftUI
import GoVibeHostCore

struct HostOnboardingView: View {
    @State var manager: HostSessionManager
    @State private var relayBase: String = ""
    @State private var shellPath: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("GoVibe Host Setup")
                    .font(.largeTitle.bold())

                Text("This Mac app hosts terminal and simulator relay sessions from one menu bar app.")
                    .foregroundStyle(.secondary)

                GroupBox("1. Host Identity") {
                    VStack(alignment: .leading, spacing: 10) {
                        identityRow(label: "Host ID", value: manager.settings.hostId)
                    }
                }

                GroupBox("2. Relay") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("wss://relay.example.com/relay", text: $relayBase)
                            .textFieldStyle(.roundedBorder)
                        Text("Set the relay WebSocket URL here. This value is stored locally after setup and is not committed to the repo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("3. Permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        permissionRow(
                            title: "Accessibility",
                            granted: manager.permissionState.accessibilityGranted,
                            actionTitle: "Request Access"
                        ) {
                            manager.requestAccessibilityAccess()
                        }
                        permissionRow(
                            title: "Screen Recording",
                            granted: manager.permissionState.screenRecordingGranted,
                            actionTitle: "Request Access"
                        ) {
                            manager.requestScreenRecordingAccess()
                        }
                    }
                }

                GroupBox("4. Terminal Defaults") {
                    TextField("Shell Path", text: $shellPath)
                        .textFieldStyle(.roundedBorder)
                }

                Button("Finish Setup") {
                    manager.completeOnboarding(
                        relayBase: relayBase,
                        defaultShellPath: shellPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? manager.settings.defaultShellPath : shellPath,
                        preferredSimulatorUDID: manager.settings.preferredSimulatorUDID
                    )
                }
                .disabled(relayBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .padding(32)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .onAppear {
            relayBase = manager.settings.relayBase
            shellPath = manager.settings.defaultShellPath
            manager.refreshEnvironment()
        }
    }

    private func permissionRow(title: String, granted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(granted ? "Granted" : "Not granted")
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .secondary)
            }
            Spacer()
            Button(actionTitle, action: action)
        }
    }

    private func identityRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 72, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.body, design: .monospaced))
    }
}

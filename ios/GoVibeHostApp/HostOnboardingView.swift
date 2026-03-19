import SwiftUI
import GoVibeHostCore

struct HostOnboardingView: View {
    @State var manager: HostSessionManager
    @State private var relayBase: String = ""
    @State private var shellPath: String = ""
    @State private var relayVerificationError: String? = nil

    private let selfHostingURL = URL(string: "https://github.com/DJBen/GoVibe/blob/main/README.md#self-hosting-production")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("GoVibe Host Setup")
                    .font(.largeTitle.bold())

                Text("This Mac app hosts terminal and simulator relay sessions from one menu bar app.")
                    .foregroundStyle(.secondary)

                GroupBox("1. Host Identity") {
                    VStack(alignment: .leading, spacing: 10) {
                        identityRow(label: "Device ID", value: manager.settings.hostId)
                    }
                }

                GroupBox("2. Relay") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("wss://relay.example.com/relay", text: $relayBase)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: relayBase) {
                                relayVerificationError = nil
                            }
                        Text("Set the relay WebSocket URL here. This value is stored locally after setup and is not committed to the repo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let error = relayVerificationError {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.subheadline)
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(error)
                                        .foregroundStyle(.red)
                                        .font(.subheadline)
                                    Link("Refer to Self-Hosting", destination: selfHostingURL)
                                        .font(.subheadline)
                                }
                            }
                            .padding(.top, 2)
                        }
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

                GroupBox("4. Dependencies") {
                    VStack(alignment: .leading, spacing: 12) {
                        dependencyRow(
                            title: "tmux",
                            detail: "Required for terminal sessions",
                            installed: manager.permissionState.tmuxInstalled,
                            isInstalling: manager.isTmuxInstalling
                        ) {
                            Task { await manager.installTmux() }
                        }
                    }
                }

                GroupBox("5. Terminal Defaults") {
                    TextField("Shell Path", text: $shellPath)
                        .textFieldStyle(.roundedBorder)
                }

                GroupBox("6. Claude Code Hook") {
                    VStack(alignment: .leading, spacing: 8) {
                        dependencyRow(
                            title: "Stop + Permission Prompt Hooks",
                            detail: "Enables 'Claude finished' and 'Unblock Claude' push notifications",
                            installed: manager.permissionState.claudeHookInstalled,
                            isInstalling: manager.isClaudeHookInstalling
                        ) {
                            Task { await manager.installClaudeHook() }
                        }
                        Text("Adds Stop and Notification hooks to ~/.claude/settings.json for reliable turn-complete and approval push notifications.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("7. Gemini CLI Hook") {
                    VStack(alignment: .leading, spacing: 8) {
                        dependencyRow(
                            title: "AfterAgent + ToolPermission Hooks",
                            detail: "Enables 'Gemini finished' and 'Unblock Gemini' push notifications",
                            installed: manager.permissionState.geminiHookInstalled,
                            isInstalling: manager.isGeminiHookInstalling
                        ) {
                            Task { await manager.installGeminiHook() }
                        }
                        Text("Adds AfterAgent and Notification hooks to ~/.gemini/settings.json for precise push notifications.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Finish Setup") {
                    finishSetup()
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

    // MARK: - Actions

    private func finishSetup() {
        let trimmed = relayBase.trimmingCharacters(in: .whitespacesAndNewlines)

        guard HostConfig.normalizedRelayHost(from: trimmed) != nil else {
            relayVerificationError = "Invalid relay host format. Expected: wss://your-relay-host/relay"
            return
        }

        manager.completeOnboarding(
            relayBase: trimmed,
            defaultShellPath: shellPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? manager.settings.defaultShellPath
                : shellPath,
            preferredSimulatorUDID: manager.settings.preferredSimulatorUDID
        )
    }

    // MARK: - Row Helpers

    private func dependencyRow(
        title: String,
        detail: String,
        installed: Bool,
        isInstalling: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(isInstalling ? "Installing via Homebrew…" : (installed ? "Installed" : detail))
                    .font(.caption)
                    .foregroundStyle(installed ? .green : .secondary)
            }
            Spacer()
            if isInstalling {
                ProgressView()
                    .controlSize(.small)
            } else if !installed {
                Button("Install via Homebrew", action: action)
            }
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

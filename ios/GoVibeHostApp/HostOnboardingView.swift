import SwiftUI
import GoVibeHostCore

struct HostOnboardingView: View {
    @State var manager: HostSessionManager
    @State private var shellPath: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("GoVibe Host Setup")
                    .font(.largeTitle.bold())

                Text("This Mac app hosts terminal and simulator relay sessions from one menu bar app.")
                    .foregroundStyle(.secondary)

                GroupBox("1. Permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            permissionRow(
                                title: "Accessibility",
                                granted: manager.permissionState.accessibilityGranted,
                                actionTitle: "Request Access"
                            ) {
                                manager.requestAccessibilityAccess()
                            }
                            Text("Enables GoVibe to control your terminal from your phone remotely.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            permissionRow(
                                title: "Screen Recording",
                                granted: manager.permissionState.screenRecordingGranted,
                                actionTitle: "Request Access"
                            ) {
                                manager.requestScreenRecordingAccess()
                            }
                            Text("Enables GoVibe to relay your screen to your phone live.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(4)
                }

                GroupBox("2. Dependencies") {
                    VStack(alignment: .leading, spacing: 12) {
                        dependencyRow(
                            title: "tmux",
                            detail: "tmux keeps terminal sessions stable and reconnectable during collaboration",
                            installed: manager.permissionState.tmuxInstalled,
                            isInstalling: manager.isTmuxInstalling,
                            buttonTitle: "Install via Homebrew"
                        ) {
                            Task { await manager.installTmux() }
                        }
                    }
                    .padding(4)
                    Text("tmux helps GoVibe Host keep shared terminal sessions running smoothly, even if the app or connection briefly drops.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                GroupBox("3. Terminal Defaults") {
                    TextField("Shell Path", text: $shellPath)
                        .textFieldStyle(.roundedBorder)
                        .padding(4)
                }

                GroupBox("4. Claude Code Hook") {
                    VStack(alignment: .leading, spacing: 8) {
                        dependencyRow(
                            title: "Stop + Permission Prompt Hooks",
                            detail: "Enables 'Claude finished' and 'Unblock Claude' push notifications",
                            installed: manager.permissionState.claudeHookInstalled,
                            isInstalling: manager.isClaudeHookInstalling
                        ) {
                            Task { await manager.installClaudeHook() }
                        }
                        Text("Get notified when Claude finishes or requires your attention so you can keep flowing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                GroupBox("5. Gemini CLI Hook") {
                    VStack(alignment: .leading, spacing: 8) {
                        dependencyRow(
                            title: "AfterAgent + ToolPermission Hooks",
                            detail: "Enables 'Gemini finished' and 'Unblock Gemini' push notifications",
                            installed: manager.permissionState.geminiHookInstalled,
                            isInstalling: manager.isGeminiHookInstalling
                        ) {
                            Task { await manager.installGeminiHook() }
                        }
                        Text("Get notified when Gemini finishes or requires your attention so you can keep flowing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                HStack {
                    Spacer()
                    Button("Finish Setup") {
                        finishSetup()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(32)
            .frame(maxWidth: 780, alignment: .leading)
        }
        .onAppear {
            shellPath = manager.settings.defaultShellPath
            manager.refreshEnvironment()
        }
    }

    // MARK: - Actions

    private func finishSetup() {
        manager.completeOnboarding(
            relayBase: manager.settings.relayBase,
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
        buttonTitle: String = "Install",
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer()
            if isInstalling {
                ProgressView()
                    .controlSize(.small)
            } else if installed {
                Text("Installed")
                    .foregroundStyle(.green)
            } else {
                Button(buttonTitle, action: action)
            }
        }
        .help(installed ? title : detail)
    }

    private func permissionRow(title: String, granted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer()
            if granted {
                Text("Granted")
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
            }
        }
    }

}

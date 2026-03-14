import SwiftUI
import GoVibeHostCore

struct HostDashboardView: View {
    @State var manager: HostSessionManager
    @State private var showingWizard = false

    var body: some View {
        NavigationSplitView {
            List(selection: $manager.selectedSessionID) {
                ForEach(manager.listSessions()) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.displayName)
                        Text("\(session.kind.rawValue.capitalized) • \(session.state.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(session.sessionId))
                }
            }
            .navigationTitle("GoVibe Host")
        } detail: {
            sessionInspector
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingWizard = true } label: {
                    Label("Add Session", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingWizard) {
            SessionCreationWizard(manager: manager)
        }
        .onAppear {
            manager.refreshPermissions()
        }
    }

    @ViewBuilder
    private var sessionInspector: some View {
        if let selectedSessionID = manager.selectedSessionID,
           let session = manager.listSessions().first(where: { $0.sessionId == selectedSessionID }) {
            GroupBox("Selected Session") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Session ID", value: session.sessionId)
                    LabeledContent("Type", value: session.kind.rawValue.capitalized)
                    LabeledContent("State", value: session.state.rawValue)
                    if let lastPeerActivityAt = session.lastPeerActivityAt {
                        LabeledContent("Last peer activity", value: lastPeerActivityAt.formatted(date: .abbreviated, time: .standard))
                    }
                    HStack {
                        Button(toggleTitle(for: session.state)) { toggleSession(session) }
                            .buttonStyle(.borderedProminent)
                        Button("Remove", role: .destructive) { manager.removeSession(id: session.sessionId) }
                    }

                    Divider()

                    Text("Logs").font(.headline)

                    ScrollView {
                        Text(logText(for: session.sessionId))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 220)
                }
            }
            .padding(24)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("No Session Selected")
                    .font(.title2).bold()
                Text("Select a session from the list or create a new one.")
                    .foregroundStyle(.secondary)
                Button("Add Session") { showingWizard = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func toggleTitle(for state: HostedSessionState) -> String {
        switch state {
        case .stopped, .error: "Start"
        default: "Stop"
        }
    }

    private func toggleSession(_ session: HostedSessionDescriptor) {
        switch session.state {
        case .stopped, .error: manager.startSession(id: session.sessionId)
        default: manager.stopSession(id: session.sessionId)
        }
    }

    private func logText(for sessionID: String) -> String {
        let lines = manager.sessionLogs(id: sessionID).map { "[\($0.level.rawValue.uppercased())] \($0.message)" }
        return lines.isEmpty ? "No logs yet." : lines.joined(separator: "\n")
    }
}

// MARK: - Session Creation Wizard

private struct SessionCreationWizard: View {
    let manager: HostSessionManager
    @Environment(\.dismiss) private var dismiss

    enum Step { case typeSelection, configure }
    enum SessionKind { case terminal, simulator }

    @State private var step: Step = .typeSelection
    @State private var selectedKind: SessionKind? = nil
    @State private var sessionID = ""
    @State private var tmuxID = ""
    @State private var simulatorUDID = ""
    @State private var pickerSimulators: [BootedSimulatorDevice] = []
    @State private var isLoadingSimulators = false

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .typeSelection: typeSelectionStep
                case .configure: configureStep
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if step == .configure {
                    ToolbarItem(placement: .navigation) {
                        Button { withAnimation { step = .typeSelection } } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step == .typeSelection {
                        Button("Next") { withAnimation { step = .configure } }
                            .disabled(selectedKind == nil)
                    } else {
                        Button("Create") { createSession() }
                            .disabled(!canCreate)
                    }
                }
            }
        }
        .frame(width: 540)
    }

    private var navigationTitle: String {
        switch step {
        case .typeSelection: "New Session"
        case .configure:
            selectedKind == .terminal ? "Terminal Relay" : "Simulator Relay"
        }
    }

    // MARK: Step 1 – Type Selection

    private var typeSelectionStep: some View {
        VStack(spacing: 24) {
            Text("What kind of relay session would you like to create?")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                typeCard(
                    kind: .terminal,
                    icon: "terminal",
                    title: "Terminal Relay",
                    description: "Stream a tmux terminal session to remote peers over WebSocket."
                )
                typeCard(
                    kind: .simulator,
                    icon: "iphone",
                    title: "Simulator Relay",
                    description: "Mirror an iOS Simulator screen to remote peers in real time."
                )
            }
            Spacer()
        }
        .padding(28)
    }

    private func typeCard(kind: SessionKind, icon: String, title: String, description: String) -> some View {
        let isSelected = selectedKind == kind
        return Button { selectedKind = kind } label: {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(height: 44)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 172)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Step 2 – Configure

    @ViewBuilder
    private var configureStep: some View {
        switch selectedKind {
        case .terminal: terminalConfigStep
        case .simulator: simulatorConfigStep
        case nil: EmptyView()
        }
    }

    private var terminalConfigStep: some View {
        Form {
            Section {
                TextField("Session ID", text: $sessionID)
            } header: {
                Text("Required")
            } footer: {
                Text("A unique identifier peers will use to connect to this session.")
            }
            Section {
                TextField("tmux Session Name", text: $tmuxID)
            } header: {
                Text("tmux (Optional)")
            } footer: {
                Text("Leave blank to use the Session ID as the tmux session name.")
            }
        }
        .formStyle(.grouped)
    }

    private var simulatorConfigStep: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Make sure your simulator is already running")
                            .font(.callout)
                            .foregroundStyle(.primary)
                        Text("Open Xcode → Open Developer Tool → Simulator, boot the device you want to mirror, then select it below. Only booted simulators appear in the list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.tint)
                }
            }

            Section {
                TextField("Session ID", text: $sessionID)
            } header: {
                Text("Required")
            } footer: {
                Text("A unique identifier peers will use to connect to this session.")
            }

            Section {
                if isLoadingSimulators {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning for booted simulators…").foregroundStyle(.secondary)
                    }
                } else if pickerSimulators.isEmpty {
                    Text("No booted simulators found. Boot one in the Simulator app and reopen this sheet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Simulator", selection: $simulatorUDID) {
                        ForEach(pickerSimulators) { sim in
                            Text("\(sim.name)  ·  \(sim.udid.prefix(8))…").tag(sim.udid)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("Target Simulator")
            }
        }
        .formStyle(.grouped)
        .task { await refreshSimulators() }
    }

    // MARK: Helpers

    private var canCreate: Bool {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if selectedKind == .simulator { return !simulatorUDID.isEmpty }
        return true
    }

    private func createSession() {
        let normalizedID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch selectedKind {
        case .terminal:
            let tmux = tmuxID.trimmingCharacters(in: .whitespacesAndNewlines)
            manager.createTerminalSession(
                config: TerminalSessionConfig(
                    sessionId: normalizedID,
                    shellPath: manager.settings.defaultShellPath,
                    tmuxSessionName: tmux.isEmpty ? normalizedID : tmux
                )
            )
        case .simulator:
            manager.createSimulatorSession(
                config: SimulatorSessionConfig(
                    sessionId: normalizedID,
                    preferredUDID: simulatorUDID
                )
            )
        case nil:
            break
        }
        dismiss()
    }

    private func refreshSimulators() async {
        isLoadingSimulators = true
        let simulators = await Task.detached(priority: .userInitiated) {
            SimulatorBridge.bootedSimulators()
        }.value
        pickerSimulators = simulators
        manager.setBootedSimulators(simulators)
        if simulators.isEmpty {
            simulatorUDID = ""
        } else if let preferred = manager.settings.preferredSimulatorUDID,
                  simulators.contains(where: { $0.udid == preferred }) {
            simulatorUDID = preferred
        } else if !simulators.contains(where: { $0.udid == simulatorUDID }) {
            simulatorUDID = simulators.first?.udid ?? ""
        }
        isLoadingSimulators = false
    }
}

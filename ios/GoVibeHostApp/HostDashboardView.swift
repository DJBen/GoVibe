import SwiftUI
import GoVibeHostCore

struct HostDashboardView: View {
    @State var manager: HostSessionManager
    @State private var terminalSessionID = ""
    @State private var tmuxSessionID = ""
    @State private var simulatorSessionID = ""
    @State private var simulatorUDID = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $manager.selectedSessionID) {
                Section("Host") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(manager.settings.hostId)
                            .font(.headline)
                        Text(manager.settings.relayBase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Sessions") {
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
            }
            .navigationTitle("GoVibe Host")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    summarySection
                    creationSection
                    sessionInspector
                }
                .padding(24)
            }
        }
        .onAppear {
            simulatorUDID = manager.settings.preferredSimulatorUDID ?? ""
            manager.refreshEnvironment()
        }
    }

    private var summarySection: some View {
        GroupBox("Host Summary") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Host ID", value: manager.settings.hostId)
                LabeledContent("Sessions", value: "\(manager.listSessions().count)")
                LabeledContent("Relay", value: manager.settings.relayBase)
                LabeledContent("Accessibility", value: manager.permissionState.accessibilityGranted ? "Granted" : "Missing")
                LabeledContent("Screen Recording", value: manager.permissionState.screenRecordingGranted ? "Granted" : "Missing")
            }
        }
    }

    private var creationSection: some View {
        HStack(alignment: .top, spacing: 20) {
            GroupBox("New Terminal Relay") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Session ID", text: $terminalSessionID)
                    TextField("tmux ID", text: $tmuxSessionID)
                    Button("Create Terminal Session") {
                        let normalizedID = terminalSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
                        let tmuxID = tmuxSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalizedID.isEmpty else { return }
                        manager.createTerminalSession(
                            config: TerminalSessionConfig(
                                sessionId: normalizedID,
                                shellPath: manager.settings.defaultShellPath,
                                tmuxSessionName: tmuxID.isEmpty ? normalizedID : tmuxID
                            )
                        )
                        terminalSessionID = ""
                        tmuxSessionID = ""
                    }
                }
            }

            GroupBox("New Simulator Relay") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Session ID", text: $simulatorSessionID)
                    Picker("Simulator UDID", selection: $simulatorUDID) {
                        Text("Use default").tag("")
                        ForEach(manager.bootedSimulators) { simulator in
                            Text("\(simulator.name) (\(simulator.udid))").tag(simulator.udid)
                        }
                    }
                    Button("Create Simulator Session") {
                        let normalizedID = simulatorSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalizedID.isEmpty else { return }
                        manager.createSimulatorSession(
                            config: SimulatorSessionConfig(
                                sessionId: normalizedID,
                                preferredUDID: simulatorUDID.isEmpty ? manager.settings.preferredSimulatorUDID : simulatorUDID
                            )
                        )
                        simulatorSessionID = ""
                    }
                }
            }
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
                        Button("Start") { manager.startSession(id: session.sessionId) }
                        Button("Stop") { manager.stopSession(id: session.sessionId) }
                        Button("Remove", role: .destructive) { manager.removeSession(id: session.sessionId) }
                    }

                    Divider()

                    Text("Logs")
                        .font(.headline)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(manager.sessionLogs(id: session.sessionId)) { entry in
                                Text("[\(entry.level.rawValue.uppercased())] \(entry.message)")
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(minHeight: 220)
                }
            }
        } else {
            ContentUnavailableView("Select a Session", systemImage: "server.rack", description: Text("Choose a hosted relay to inspect logs and controls."))
        }
    }
}

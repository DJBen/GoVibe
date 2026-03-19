import SwiftUI
import GoVibeHostCore

struct HostDashboardView: View {
    @State var manager: HostSessionManager
    @State private var showingWizard = false
    @State private var showingHostIDPopover = false
    private let relativeDateFormatter = RelativeDateTimeFormatter()
    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yMdjmmsszzz")
        return formatter
    }()

    var body: some View {
        NavigationSplitView {
            List(selection: $manager.selectedSessionID) {
                ForEach(manager.listSessions()) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.displayName)
                        Text("\(session.kind.rawValue.capitalized) • \(stateDescription(for: session))")
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
                Button {
                    showingHostIDPopover = true
                } label: {
                    Label("Show Host ID", systemImage: "number")
                }
                .popover(isPresented: $showingHostIDPopover, arrowEdge: .top) {
                    HostIDView(hostId: manager.settings.hostId)
                }
            }
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
            manager.startControlChannel()
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
                    LabeledContent("State", value: stateDescription(for: session))
                    if let lastPeerActivityAt = session.lastPeerActivityAt {
                        LabeledContent("Last active", value: relativeDateFormatter.localizedString(for: lastPeerActivityAt, relativeTo: .now))
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
            .padding(24)
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
        let lines = manager.sessionLogs(id: sessionID).map {
            let timestamp = Self.logTimestampFormatter.string(from: $0.timestamp)
            return "[\(timestamp)] [\($0.level.rawValue.uppercased())] \($0.message)"
        }
        return lines.isEmpty ? "No logs yet." : lines.joined(separator: "\n")
    }

    private func stateDescription(for session: HostedSessionDescriptor) -> String {
        if session.state == .stale {
            if let lastPeerActivityAt = session.lastPeerActivityAt {
                return "Last active \(relativeDateFormatter.localizedString(for: lastPeerActivityAt, relativeTo: .now))"
            }
            return "Last active a while ago"
        }

        return session.state.displayLabel
    }
}

// MARK: - Session Creation Wizard

private struct SessionCreationWizard: View {
    let manager: HostSessionManager
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    enum Step { case typeSelection, configure }
    enum SessionKind { case terminal, simulator, appWindow }
    enum Field: Hashable { case sessionID, tmuxID }

    @State private var step: Step = .typeSelection
    @State private var selectedKind: SessionKind? = nil
    @State private var sessionID = ""
    @State private var sessionIDPrompt = ""
    @State private var tmuxID = ""
    @State private var simulatorUDID = ""
    @State private var pickerSimulators: [BootedSimulatorDevice] = []
    @State private var isLoadingSimulators = false
    @State private var availableWindows: [AvailableWindow] = []
    @State private var selectedWindow: AvailableWindow? = nil
    @State private var isLoadingWindows = false
    @State private var windowSearchText = ""

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
        .frame(width: 640)
    }

    private var navigationTitle: String {
        switch step {
        case .typeSelection: "New Session"
        case .configure:
            switch selectedKind {
            case .terminal: "Terminal Relay"
            case .simulator: "Simulator Relay"
            case .appWindow: "Application Window"
            case nil: "Configure"
            }
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
                typeCard(
                    kind: .appWindow,
                    icon: "macwindow",
                    title: "Application Window",
                    description: "Mirror any macOS application window to remote peers in real time."
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
        case .appWindow: appWindowConfigStep
        case nil: EmptyView()
        }
    }

    private var terminalConfigStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                formIntro(
                    title: "Give this relay a name peers can connect to.",
                    subtitle: "You can optionally point it at a specific tmux session, or leave that blank and reuse the Session ID."
                )

                inputBlock(
                    title: "Session ID",
                    help: "A unique identifier peers will use to connect to this relay."
                ) {
                    TextField("", text: $sessionID, prompt: Text("e.g. ios-dev"))
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .sessionID)
                }

                inputBlock(
                    title: "tmux Session",
                    help: "Optional. Leave blank to use the Session ID as the tmux session name."
                ) {
                    TextField("", text: $tmuxID, prompt: Text("Optional tmux session name"))
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .tmuxID)
                }
            }
            .padding(28)
        }
        .onAppear { focusedField = .sessionID }
    }

    private var simulatorConfigStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                formIntro(
                    title: "Choose a relay name, then pick a booted simulator to mirror.",
                    subtitle: "Open Xcode → Open Developer Tool → Simulator and boot the device first. Only active simulators appear here."
                )

                inputBlock(
                    title: "Session ID",
                    help: "A unique identifier peers will use to connect to this relay."
                ) {
                    TextField("", text: $sessionID, prompt: Text(sessionIDPrompt.isEmpty ? "e.g. sim-ios-18" : sessionIDPrompt).foregroundColor(.secondary))
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .sessionID)
                }

                inputBlock(
                    title: "Target Simulator",
                    help: "Pick one of the currently booted simulators."
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(selectionSummary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                Task { await refreshSimulators() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.borderless)
                            .disabled(isLoadingSimulators)
                            .help("Refresh booted simulators")
                        }

                        if isLoadingSimulators {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Scanning for booted simulators…")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                        } else if pickerSimulators.isEmpty {
                            Text("No booted simulators found. Boot one in the Simulator app, then refresh.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(pickerSimulators) { sim in
                                    simulatorOptionRow(sim)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .task { await refreshSimulators() }
        .onAppear { focusedField = .sessionID }
    }

    // MARK: Helpers

    private var effectiveSessionID: String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? sessionIDPrompt : trimmed
    }

    private var canCreate: Bool {
        guard !effectiveSessionID.isEmpty else { return false }
        if selectedKind == .simulator { return !simulatorUDID.isEmpty }
        if selectedKind == .appWindow { return selectedWindow != nil }
        return true
    }

    private func createSession() {
        let normalizedID = effectiveSessionID
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
        case .appWindow:
            if let window = selectedWindow {
                manager.createAppWindowSession(
                    config: AppWindowSessionConfig(
                        sessionId: normalizedID,
                        windowTitle: window.title,
                        bundleIdentifier: window.bundleIdentifier
                    )
                )
            }
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
        if let selected = simulators.first(where: { $0.udid == simulatorUDID }) ?? simulators.first {
            sessionIDPrompt = selected.name
        }
        isLoadingSimulators = false
    }

    private var appWindowConfigStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                formIntro(
                    title: "Choose a relay name, then pick a window to mirror.",
                    subtitle: "Any visible macOS application window can be mirrored. Grant screen recording permission if prompted."
                )

                inputBlock(
                    title: "Session ID",
                    help: "A unique identifier peers will use to connect to this relay."
                ) {
                    TextField("", text: $sessionID, prompt: Text(sessionIDPrompt.isEmpty ? "e.g. safari-window" : sessionIDPrompt).foregroundColor(.secondary))
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .sessionID)
                }

                inputBlock(
                    title: "Target Window",
                    help: "Pick one of the currently visible application windows."
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(windowSelectionSummary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                Task { await refreshWindows() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.borderless)
                            .disabled(isLoadingWindows)
                            .help("Refresh available windows")
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                            TextField("Search apps or windows…", text: $windowSearchText)
                                .textFieldStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.06))
                        }

                        if isLoadingWindows {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Scanning for application windows…")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                        } else if filteredWindowsByApp.isEmpty {
                            Text(availableWindows.isEmpty
                                 ? "No application windows found. Make sure other apps are open and visible, then refresh."
                                 : "No windows match your search.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        } else {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(filteredWindowsByApp, id: \.appName) { group in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(group.appName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 4)
                                        VStack(spacing: 6) {
                                            ForEach(group.windows) { window in
                                                windowOptionRow(window)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .task { await refreshWindows() }
        .onAppear { focusedField = .sessionID }
    }

    private func refreshWindows() async {
        isLoadingWindows = true
        let windows: [AvailableWindow]
        do {
            windows = try await AppWindowBridge.listWindows()
        } catch {
            windows = []
        }
        availableWindows = windows
        if let selected = selectedWindow, !windows.contains(where: { $0.id == selected.id }) {
            selectedWindow = windows.first
        } else if selectedWindow == nil {
            selectedWindow = windows.first
        }
        if let selected = selectedWindow {
            sessionIDPrompt = selected.appName
        }
        isLoadingWindows = false
    }

    private var windowSelectionSummary: String {
        guard let selected = selectedWindow else {
            return "Choose one of the visible windows below."
        }
        return "Selected: \(selected.appName) – \(selected.title)"
    }

    private var filteredWindowsByApp: [(appName: String, windows: [AvailableWindow])] {
        let filtered = windowSearchText.isEmpty
            ? availableWindows
            : availableWindows.filter {
                $0.appName.localizedCaseInsensitiveContains(windowSearchText) ||
                $0.title.localizedCaseInsensitiveContains(windowSearchText)
            }
        var appOrder: [String] = []
        var groupMap: [String: [AvailableWindow]] = [:]
        for window in filtered {
            if groupMap[window.appName] == nil {
                appOrder.append(window.appName)
                groupMap[window.appName] = []
            }
            groupMap[window.appName]!.append(window)
        }
        return appOrder.map { (appName: $0, windows: groupMap[$0]!) }
    }

    private func windowOptionRow(_ window: AvailableWindow) -> some View {
        let isSelected = selectedWindow?.id == window.id
        return Button {
            selectedWindow = window
            sessionIDPrompt = window.appName
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(window.title)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func formIntro(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inputBlock<Content: View>(
        title: String,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.045))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            Text(help)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectionSummary: String {
        guard let selected = pickerSimulators.first(where: { $0.udid == simulatorUDID }) else {
            return "Choose one of the booted simulators below."
        }
        return "Selected: \(selected.name)"
    }

    private func simulatorOptionRow(_ simulator: BootedSimulatorDevice) -> some View {
        let isSelected = simulator.udid == simulatorUDID
        return Button {
            simulatorUDID = simulator.udid
            sessionIDPrompt = simulator.name
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(simulator.name)
                        .foregroundStyle(.primary)
                    Text(simulator.udid)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

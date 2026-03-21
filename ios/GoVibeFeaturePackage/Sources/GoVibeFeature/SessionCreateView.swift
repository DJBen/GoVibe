import SwiftUI

struct SessionCreateView: View {
    let host: HostInfo
    let store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var sessionId = ""
    @State private var tmuxSession = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?
    @State private var tmuxMode: TmuxMode = .new
    @State private var existingTmuxSessions: [String] = []
    @State private var isLoadingTmuxSessions = false
    @State private var tmuxLoadError: String?
    @State private var selectedTmuxSession: String? = nil

    private enum Field: Hashable { case sessionId, tmuxSession }
    private enum TmuxMode { case new, existing }

    private var canCreate: Bool {
        !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $tmuxMode) {
                        Text("New Session").tag(TmuxMode.new)
                        Text("Existing Session").tag(TmuxMode.existing)
                    }
                    .pickerStyle(.segmented)

                    if tmuxMode == .new {
                        TextField("e.g. main", text: $tmuxSession)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focusedField, equals: .tmuxSession)
                            .onChange(of: tmuxSession) { _, newValue in
                                sessionId = newValue
                            }
                    }
                } header: {
                    Text("tmux Session")
                } footer: {
                    Text(tmuxMode == .new
                         ? "The Session ID will be pre-filled as you type."
                         : "Select a running tmux session on the host to attach to.")
                }

                if tmuxMode == .existing {
                    Section {
                        if isLoadingTmuxSessions {
                            HStack(spacing: 12) {
                                ProgressView().controlSize(.small)
                                Text("Loading sessions…")
                                    .foregroundStyle(.secondary)
                            }
                        } else if let tmuxLoadError {
                            Text(tmuxLoadError)
                                .foregroundStyle(.red)
                                .font(.footnote)
                        } else if existingTmuxSessions.isEmpty {
                            Text("No running tmux sessions found.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(existingTmuxSessions, id: \.self) { session in
                                tmuxSessionRow(session)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Running Sessions")
                            Spacer()
                            Button {
                                Task { await loadTmuxSessions() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.callout)
                            }
                            .disabled(isLoadingTmuxSessions)
                        }
                    }
                }

                Section {
                    TextField("e.g. ios-dev", text: $sessionId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .sessionId)
                } header: {
                    Text("Session ID")
                } footer: {
                    Text("A unique identifier peers will use to connect to this relay.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Terminal Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Create") {
                            Task { await createSession() }
                        }
                        .disabled(!canCreate)
                    }
                }
            }
            .task(id: tmuxMode) {
                guard tmuxMode == .existing else { return }
                if existingTmuxSessions.isEmpty {
                    await loadTmuxSessions()
                } else if tmuxSession.isEmpty, selectedTmuxSession == nil,
                          let eligible = existingTmuxSessions.first(where: { !isTmuxSessionAlreadyAdded($0) }) {
                    selectedTmuxSession = eligible
                    sessionId = eligible
                }
            }
        }
    }

    @ViewBuilder
    private func tmuxSessionRow(_ session: String) -> some View {
        let isAdded = isTmuxSessionAlreadyAdded(session)
        Button {
            guard !isAdded else { return }
            selectedTmuxSession = session
            sessionId = session
        } label: {
            HStack {
                Text(session)
                    .foregroundStyle(isAdded ? .tertiary : .primary)
                Spacer()
                if isAdded {
                    Text("Added")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if selectedTmuxSession == session {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func isTmuxSessionAlreadyAdded(_ name: String) -> Bool {
        store.sessions(for: host.id).contains { $0.sessionId == name }
    }

    private func loadTmuxSessions() async {
        isLoadingTmuxSessions = true
        tmuxLoadError = nil
        defer { isLoadingTmuxSessions = false }
        let client = HostControlClient(
            relayWebSocketBase: AppRuntimeConfig.relayWebSocketBase,
            apiBaseURL: AppRuntimeConfig.apiBaseURL
        )
        do {
            let sessions = try await client.listTmuxSessions(hostId: host.id)
            existingTmuxSessions = sessions
            if selectedTmuxSession == nil,
               let eligible = sessions.first(where: { !isTmuxSessionAlreadyAdded($0) }) {
                selectedTmuxSession = eligible
                sessionId = eligible
            }
        } catch {
            existingTmuxSessions = []
            tmuxLoadError = error.localizedDescription
        }
    }

    private func createSession() async {
        let trimmedId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        let effectiveTmux: String?
        if tmuxMode == .existing {
            effectiveTmux = selectedTmuxSession
        } else {
            let trimmedTmux = tmuxSession.trimmingCharacters(in: .whitespacesAndNewlines)
            effectiveTmux = trimmedTmux.isEmpty ? nil : trimmedTmux
        }

        let client = HostControlClient(
            relayWebSocketBase: AppRuntimeConfig.relayWebSocketBase,
            apiBaseURL: AppRuntimeConfig.apiBaseURL
        )
        do {
            try await client.createSession(
                hostId: host.id,
                sessionId: trimmedId,
                tmuxSession: effectiveTmux
            )
            store.add(sessionId: trimmedId, hostId: host.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

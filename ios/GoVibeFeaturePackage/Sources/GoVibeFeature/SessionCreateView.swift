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

    private enum Field: Hashable { case sessionId, tmuxSession }

    private var canCreate: Bool {
        !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. ios-dev", text: $sessionId)
                        .autocorrectionDisabled()
#if canImport(UIKit)
                        .textInputAutocapitalization(.never)
#endif
                        .focused($focusedField, equals: .sessionId)
                } header: {
                    Text("Session ID")
                } footer: {
                    Text("A unique identifier peers will use to connect to this relay.")
                }

                Section {
                    TextField("Optional tmux session name", text: $tmuxSession)
                        .autocorrectionDisabled()
#if canImport(UIKit)
                        .textInputAutocapitalization(.never)
#endif
                        .focused($focusedField, equals: .tmuxSession)
                } header: {
                    Text("tmux Session")
                } footer: {
                    Text("Leave blank to reuse the Session ID as the tmux session name.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Terminal Session")
#if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
#endif
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
            .onAppear { focusedField = .sessionId }
        }
    }

    private func createSession() async {
        let trimmedId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTmux = tmuxSession.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        let client = HostControlClient(relayWebSocketBase: AppRuntimeConfig.relayWebSocketBase)
        do {
            try await client.createSession(
                hostId: host.id,
                sessionId: trimmedId,
                tmuxSession: trimmedTmux.isEmpty ? nil : trimmedTmux
            )
            store.add(roomId: trimmedId, hostId: host.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

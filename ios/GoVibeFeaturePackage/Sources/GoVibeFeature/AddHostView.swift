import SwiftUI

struct AddHostView: View {
    let store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var hostName = ""
    @State private var hostId = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case hostName, hostId }

    private var canAdd: Bool {
        !hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !hostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Work MacBook Pro", text: $hostName)
                        .focused($focusedField, equals: .hostName)
                } header: {
                    Text("Host Name")
                } footer: {
                    Text("A friendly label to identify this Mac in your session list.")
                }

                Section {
                    TextField("Paste Host ID here", text: $hostId)
                        .autocorrectionDisabled()
#if canImport(UIKit)
                        .textInputAutocapitalization(.never)
#endif
                        .font(.system(.body, design: .monospaced))
                        .focused($focusedField, equals: .hostId)
                } header: {
                    Text("Host ID")
                } footer: {
                    Text("Find this in the GoVibe Host app on your Mac — tap \"Copy Host ID\" in the session inspector.")
                }
            }
            .navigationTitle("Add Mac Host")
#if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmedId = hostId.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedName = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.addHost(id: trimmedId, name: trimmedName)
                        // Fetch sessions from the new host in the background.
                        let host = HostInfo(id: trimmedId, name: trimmedName)
                        Task { await store.syncSessions(for: host) }
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
            .onAppear { focusedField = .hostName }
        }
    }
}

import SwiftUI
import GoVibeHostCore
import AppKit
import FirebaseAuth

struct HostSettingsView: View {
    @State var manager: HostSessionManager
    var onSignOut: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedSection: SettingsSection? = .general
    @State private var showingDeleteConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteError: String?
    @State private var didCopyDeviceID = false
    @State private var didCopyToken = false
    @State private var isLoadingToken = false

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: sectionIcon(for: section))
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch selectedSection {
            case .general:
                generalDetail
            case nil:
                Text("Select a section")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 600, minHeight: 480)
    }

    private func sectionIcon(for section: SettingsSection) -> String {
        switch section {
        case .general: "gearshape"
        }
    }

    // MARK: - General

    private var generalDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("General")
                    .font(.title2.bold())
                    .padding(.bottom, 20)

                settingsRow(
                    icon: "wrench.and.screwdriver",
                    title: "Set Up GoVibe",
                    description: "Run the guided setup again to configure permissions, install dependencies, and set terminal defaults."
                ) {
                    Button("Set Up") {
                        manager.restartSetup()
                        activateMainWindow()
                    }
                }

                Divider().padding(.vertical, 12)

                // Device ID
                copiableRow(
                    icon: "number",
                    title: "Device ID",
                    description: "Unique machine identifier used for discovery, ownership, and relay routing.",
                    value: manager.settings.hostId,
                    didCopy: $didCopyDeviceID
                )

                Divider().padding(.vertical, 12)

                // Firebase ID Token
                settingsRow(
                    icon: "key",
                    title: "Firebase ID Token",
                    description: "Short-lived JWT used to authenticate API calls. Expires after 1 hour."
                ) {
                    HStack(spacing: 8) {
                        if isLoadingToken {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button {
                            copyToken()
                        } label: {
                            Text(didCopyToken ? "Copied!" : "Copy")
                                .foregroundStyle(didCopyToken ? .green : .primary)
                        }
                        .disabled(isLoadingToken)
                    }
                }

                Divider().padding(.vertical, 12)

                settingsRow(
                    icon: "trash",
                    title: "Delete My Account",
                    description: "Permanently delete all cloud data (devices, sessions) and erase local data. You will be signed out."
                ) {
                    Button("Delete Account", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isDeletingAccount)
                }

                if let deleteError {
                    Text(deleteError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.top, 8)
                }
            }
            .padding(24)
            .overlay {
                if isDeletingAccount {
                    ZStack {
                        Color.black.opacity(0.15)
                        ProgressView("Deleting account\u{2026}")
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete your GoVibe account?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete My Account", role: .destructive) {
                performAccountDeletion()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all your cloud data, stop all sessions, erase local settings, and sign you out. This cannot be undone.")
        }
    }

    // MARK: - Helpers

    private func settingsRow<Accessory: View>(
        icon: String,
        title: String,
        description: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            accessory()
                .padding(.top, 2)
        }
    }

    private func copiableRow(
        icon: String,
        title: String,
        description: String,
        value: String,
        didCopy: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .center)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    didCopy.wrappedValue = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        didCopy.wrappedValue = false
                    }
                } label: {
                    Text(didCopy.wrappedValue ? "Copied!" : "Copy")
                        .foregroundStyle(didCopy.wrappedValue ? .green : .primary)
                }
                .padding(.top, 2)
            }

            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func copyToken() {
        isLoadingToken = true
        Task {
            do {
                if let token = try await Auth.auth().currentUser?.getIDToken() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
                    didCopyToken = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        didCopyToken = false
                    }
                }
            } catch {
                // Token fetch failed silently — user can retry.
            }
            isLoadingToken = false
        }
    }

    private func performAccountDeletion() {
        isDeletingAccount = true
        deleteError = nil
        Task {
            do {
                try await manager.deleteAccount()
                onSignOut()
                dismiss()
                activateMainWindow()
            } catch {
                deleteError = "Failed to delete account: \(error.localizedDescription)"
            }
            isDeletingAccount = false
        }
    }

    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.title == "GoVibe Host" }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

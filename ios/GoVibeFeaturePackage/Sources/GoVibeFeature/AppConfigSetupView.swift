import SwiftUI

public struct AppConfigSetupView: View {
    private let config = AppConfig.shared
    @Environment(\.dismiss) var dismiss

    @State private var relayHost: String

    @State private var isVerifying = false
    @State private var verificationMessage: String?
    @State private var showVerificationError = false

    public init() {
        _relayHost = State(initialValue: AppConfig.shared.relayHost)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Relay Configuration") {
                    TextField("Relay Host (e.g. govibe-relay...)", text: $relayHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section {
                    Button {
                        verifyAndSave()
                    } label: {
                        HStack {
                            Text("Verify & Save")
                            if isVerifying {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!isDraftValid || isVerifying)
                }

                if let message = verificationMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(showVerificationError ? .red : .green)
                    }
                }

                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        config.reset()
                        relayHost = config.relayHost
                    }
                }
            }
            .navigationTitle("Setup GoVibe")
        }
    }

    private func verifyAndSave() {
        isVerifying = true
        verificationMessage = nil
        showVerificationError = false

        Task {
            let relay = relayHost.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !relay.isEmpty, normalizedRelayHost(from: relay) != nil else {
                verificationMessage = "Invalid relay host format."
                showVerificationError = true
                isVerifying = false
                return
            }

            config.save(relay: relay)

            try? await Task.sleep(for: .seconds(0.5))

            isVerifying = false
            dismiss()
        }
    }

    private var isDraftValid: Bool {
        !relayHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func normalizedRelayHost(from input: String) -> String? {
        if let url = URL(string: input), let host = url.host, !host.isEmpty {
            return host
        }

        var host = input
        if let schemeIndex = host.range(of: "://") {
            host = String(host[schemeIndex.upperBound...])
        }
        if let slashIndex = host.firstIndex(of: "/") {
            host = String(host[..<slashIndex])
        }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedHost.isEmpty ? nil : trimmedHost
    }
}

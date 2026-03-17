import SwiftUI
import GoVibeHostCore

struct HostConfigSetupView: View {
    private let config = HostConfig.shared
    @Environment(\.dismiss) var dismiss

    @State private var relayHost: String

    @State private var isVerifying = false
    @State private var verificationMessage: String?
    @State private var showVerificationError = false

    init() {
        _relayHost = State(initialValue: HostConfig.shared.relayHost)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                Text("Relay Configuration")
                    .font(.title3.weight(.semibold))
                Text("Connect GoVibe Host to your relay server.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .padding(.horizontal, 24)

            Divider()

            // Field
            VStack(alignment: .leading, spacing: 5) {
                Text("Relay Hostname")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    TextField("my-relay.run.app", text: $relayHost)
                        .textFieldStyle(.roundedBorder)
                    if isDraftValid {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Text("Hostname only — no https:// or trailing slash.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)

            // Validation message
            if let message = verificationMessage {
                HStack(spacing: 6) {
                    Image(systemName: showVerificationError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.subheadline)
                    Text(message)
                        .font(.subheadline)
                }
                .foregroundStyle(showVerificationError ? Color.red : Color.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            Divider()

            // Footer
            HStack {
                Button("Reset to Default", role: .destructive) {
                    config.reset()
                    relayHost = config.relayHost
                    verificationMessage = nil
                }
                .foregroundStyle(.red)

                Spacer()

                Button {
                    verifyAndSave()
                } label: {
                    HStack(spacing: 6) {
                        if isVerifying {
                            ProgressView().controlSize(.small)
                        }
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isDraftValid || isVerifying)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 400, alignment: .top)
    }

    private func verifyAndSave() {
        isVerifying = true
        verificationMessage = nil
        showVerificationError = false

        Task {
            let trimmedRelayHost = relayHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedRelayHost(from: trimmedRelayHost) != nil else {
                verificationMessage = "Invalid configuration format."
                showVerificationError = true
                isVerifying = false
                return
            }

            config.save(relay: trimmedRelayHost)

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

import SwiftUI
import GoVibeHostCore

struct HostConfigSetupView: View {
    @Bindable var config = HostConfig.shared
    @Environment(\.dismiss) var dismiss

    @State private var isVerifying = false
    @State private var verificationMessage: String?
    @State private var showVerificationError = false

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
                    TextField("my-relay.run.app", text: $config.relayHost)
                        .textFieldStyle(.roundedBorder)
                    if config.isValid {
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
                .disabled(!config.isValid || isVerifying)
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
            config.save(relay: config.relayHost)

            guard config.relayWebSocketBase != nil else {
                verificationMessage = "Invalid configuration format."
                showVerificationError = true
                isVerifying = false
                return
            }

            try? await Task.sleep(for: .seconds(0.5))

            isVerifying = false
            dismiss()
        }
    }
}

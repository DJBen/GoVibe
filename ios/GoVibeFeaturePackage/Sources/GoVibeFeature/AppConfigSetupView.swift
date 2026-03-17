import SwiftUI

public struct AppConfigSetupView: View {
    private let config = AppConfig.shared
    @Environment(\.dismiss) var dismiss

    @State private var gcpProjectID: String
    @State private var gcpRegion: String
    @State private var relayHost: String
    
    @State private var isVerifying = false
    @State private var verificationMessage: String?
    @State private var showVerificationError = false
    
    public init() {
        let config = AppConfig.shared
        _gcpProjectID = State(initialValue: config.gcpProjectID)
        _gcpRegion = State(initialValue: config.gcpRegion)
        _relayHost = State(initialValue: config.relayHost)
    }
    
    public var body: some View {
        NavigationStack {
            Form {
                Section("GCP Configuration") {
                    TextField("Project ID", text: $gcpProjectID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Region", text: $gcpRegion)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                
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
                        syncDraftsFromConfig()
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
            let projectID = gcpProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
            let region = gcpRegion.trimmingCharacters(in: .whitespacesAndNewlines)
            let relay = relayHost.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Basic format check
            guard
                !projectID.isEmpty,
                !region.isEmpty,
                !relay.isEmpty,
                URL(string: "https://\(region)-\(projectID).cloudfunctions.net/api") != nil,
                normalizedRelayHost(from: relay) != nil
            else {
                verificationMessage = "Invalid configuration format."
                showVerificationError = true
                isVerifying = false
                return
            }

            config.save(projectID: projectID, region: region, relay: relay)
            
            // Simulate network check / handshake here if desired
            try? await Task.sleep(for: .seconds(0.5))
            
            isVerifying = false
            dismiss()
        }
    }

    private var isDraftValid: Bool {
        !gcpProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !gcpRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !relayHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func syncDraftsFromConfig() {
        gcpProjectID = config.gcpProjectID
        gcpRegion = config.gcpRegion
        relayHost = config.relayHost
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

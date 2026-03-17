import SwiftUI
import Observation

public struct AppConfigSetupView: View {
    @Bindable var config = AppConfig.shared
    @Environment(\.dismiss) var dismiss
    
    @State private var isVerifying = false
    @State private var verificationMessage: String?
    @State private var showVerificationError = false
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            Form {
                Section("GCP Configuration") {
                    TextField("Project ID", text: $config.gcpProjectID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Region", text: $config.gcpRegion)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                
                Section("Relay Configuration") {
                    TextField("Relay Host (e.g. govibe-relay...)", text: $config.relayHost)
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
                    .disabled(!config.isValid || isVerifying)
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
            // Save currently entered values
            config.save(
                projectID: config.gcpProjectID,
                region: config.gcpRegion,
                relay: config.relayHost
            )
            
            // Basic format check
            guard let _ = config.apiBaseURL, let _ = config.relayWebSocketBase else {
                verificationMessage = "Invalid configuration format."
                showVerificationError = true
                isVerifying = false
                return
            }
            
            // Simulate network check / handshake here if desired
            try? await Task.sleep(for: .seconds(0.5))
            
            isVerifying = false
            dismiss()
        }
    }
}

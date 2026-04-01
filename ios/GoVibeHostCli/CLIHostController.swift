import Foundation
import GoVibeHostCore
@preconcurrency import FirebaseCore
@preconcurrency import FirebaseFirestore

/// Orchestrates the full CLI host lifecycle:
/// authenticate → register host → start terminal session → relay.
struct CLIHostController {
    let authConfig: CLIAuthConfig
    let credentialStore = CLICredentialStore()

    func run(sessionName: String?, shellPath: String?) async throws {
        print("GoVibe Host CLI\n")

        // 1. Authenticate
        let (credentials, tokenProvider) = try await authenticate()
        print("Registering host \"\(Host.current().localizedName ?? "unknown")\"...")

        // 2. Configure Firebase for Firestore (not for Auth — we use REST)
        configureFirebaseForFirestore()

        // 3. Load host config
        let config = await MainActor.run { HostConfig.shared }
        guard let apiBaseURL = await MainActor.run(body: { config.apiBaseURL }),
              let relayBase = await MainActor.run(body: { config.relayWebSocketBase }) else {
            throw CLIError.missingConfig
        }

        // 4. Resolve host identity
        let hostId = HostMachineIdentity.resolveHostID(userID: credentials.uid)

        // 5. Register host with backend
        let apiClient = HostAPIClient(baseURL: apiBaseURL, tokenProvider: tokenProvider)
        let payload = HostRegistrationPayload(
            deviceId: hostId,
            displayName: Host.current().localizedName ?? "CLI Host",
            capabilities: ["terminal"],
            discoveryVisible: true,
            appVersion: nil,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        try await apiClient.registerHost(payload)
        print("✓ Host registered")

        // 6. Sync session to Firestore
        let effectiveSessionName = sessionName ?? "default"
        let effectiveShell = shellPath ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let sessionConfig = TerminalSessionConfig(
            sessionId: effectiveSessionName,
            shellPath: effectiveShell,
            tmuxSessionName: effectiveSessionName
        )

        let sessionSync = HostSessionSync()
        await sessionSync.configure(hostId: hostId, ownerUid: credentials.uid)

        let descriptor = HostedSessionDescriptor(
            hostId: hostId,
            sessionId: effectiveSessionName,
            kind: .terminal,
            displayName: effectiveSessionName,
            state: .running,
            configuration: .terminal(sessionConfig)
        )
        await sessionSync.upsert(descriptor)

        // 7. Create and start the terminal session
        let logger = HostLogger(sessionId: effectiveSessionName, printToStdout: true) { _ in }
        let session = TerminalHostSession(
            hostId: hostId,
            config: sessionConfig,
            relayBase: relayBase,
            logger: logger,
            tokenProvider: tokenProvider
        )

        print("Starting terminal session \"\(effectiveSessionName)\"...")
        try session.start()
        print("✓ Relay connected. Session visible on your iOS device.\n")
        print("Press Ctrl+C to stop.\n")

        // 8. Handle SIGINT/SIGTERM for graceful shutdown
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            signalSource.setEventHandler {
                signalSource.cancel()
                continuation.resume()
            }
            signalSource.resume()

            let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            signal(SIGTERM, SIG_IGN)
            sigTermSource.setEventHandler {
                sigTermSource.cancel()
                continuation.resume()
            }
            sigTermSource.resume()
        }

        print("\nShutting down...")
        session.stop()
        await sessionSync.remove(sessionId: effectiveSessionName)
        print("Session stopped. Goodbye.")
    }

    func signOut() {
        credentialStore.delete()
        print("Credentials removed. Signed out.")
    }

    // MARK: - Authentication

    private func authenticate() async throws -> (CLICredentials, RESTTokenProvider) {
        guard authConfig.isValid else {
            throw CLIError.missingAuthConfig
        }

        let firebaseAuth = FirebaseRESTAuth(apiKey: authConfig.firebaseAPIKey)
        let tokenProvider = RESTTokenProvider(
            credentialStore: credentialStore,
            firebaseAPIKey: authConfig.firebaseAPIKey
        )

        // Try to restore existing credentials
        if let existing = try? credentialStore.load() {
            if existing.expiresAt.timeIntervalSinceNow > 300 {
                print("Restoring session... ✓ Signed in as \(existing.email ?? existing.uid)")
                tokenProvider.updateCredentials(existing)
                return (existing, tokenProvider)
            }

            // Token expired — try refresh
            do {
                let refreshed = try await firebaseAuth.refreshToken(existing.firebaseRefreshToken)
                var updated = existing
                updated.firebaseIdToken = refreshed.idToken
                updated.firebaseRefreshToken = refreshed.refreshToken
                updated.expiresAt = Date().addingTimeInterval(TimeInterval(refreshed.expiresIn))
                try credentialStore.save(updated)
                print("Restoring session... ✓ Signed in as \(updated.email ?? updated.uid)")
                tokenProvider.updateCredentials(updated)
                return (updated, tokenProvider)
            } catch {
                print("Session expired. Signing in again...")
            }
        } else {
            print("No saved credentials. Signing in with Google...")
        }

        // Full device flow sign-in
        let deviceFlow = DeviceFlowAuth(
            clientID: authConfig.googleDeviceClientID,
            clientSecret: authConfig.googleDeviceClientSecret
        )
        print("Waiting for sign-in...", terminator: " ")
        fflush(stdout)

        let googleResult = try await deviceFlow.signIn()

        // Exchange for Firebase credentials
        let firebaseResult = try await firebaseAuth.signInWithGoogle(idToken: googleResult.idToken)
        let credentials = CLICredentials(
            firebaseIdToken: firebaseResult.idToken,
            firebaseRefreshToken: firebaseResult.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(firebaseResult.expiresIn)),
            uid: firebaseResult.localId,
            email: firebaseResult.email,
            displayName: firebaseResult.displayName
        )
        try credentialStore.save(credentials)
        print("✓ Signed in as \(credentials.email ?? credentials.uid)")
        tokenProvider.updateCredentials(credentials)
        return (credentials, tokenProvider)
    }

    // MARK: - Firebase Configuration (Firestore only)

    private func configureFirebaseForFirestore() {
        guard FirebaseApp.app() == nil else { return }

        let env = ProcessInfo.processInfo.environment
        let projectID = env["GOVIBE_GCP_PROJECT_ID"] ?? ""
        let apiKey = authConfig.firebaseAPIKey

        guard !projectID.isEmpty, !apiKey.isEmpty else {
            print("⚠ Firebase Firestore not configured (missing project ID or API key)")
            return
        }

        let options = FirebaseOptions(
            googleAppID: env["GOVIBE_FIREBASE_APP_ID"] ?? "1:000000000000:macos:0000000000000000",
            gcmSenderID: env["GOVIBE_GCM_SENDER_ID"] ?? "000000000000"
        )
        options.projectID = projectID
        options.apiKey = apiKey
        FirebaseApp.configure(options: options)
    }
}

enum CLIError: LocalizedError {
    case missingConfig
    case missingAuthConfig

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Host configuration is incomplete. Set GOVIBE_GCP_PROJECT_ID, GOVIBE_GCP_REGION, and GOVIBE_GCP_RELAY_HOST."
        case .missingAuthConfig:
            return "Auth configuration is incomplete. Set GOVIBE_FIREBASE_API_KEY, GOVIBE_GOOGLE_DEVICE_CLIENT_ID, and GOVIBE_GOOGLE_DEVICE_CLIENT_SECRET."
        }
    }
}

import Foundation
import GoVibeHostCore

/// `HostTokenProvider` implementation that manages Firebase ID tokens via REST API,
/// automatically refreshing expired tokens using the stored refresh token.
final class RESTTokenProvider: HostTokenProvider, @unchecked Sendable {
    private let credentialStore: CLICredentialStore
    private let firebaseAuth: FirebaseRESTAuth
    private let lock = NSLock()
    private var cachedCredentials: CLICredentials?

    init(credentialStore: CLICredentialStore, firebaseAPIKey: String) {
        self.credentialStore = credentialStore
        self.firebaseAuth = FirebaseRESTAuth(apiKey: firebaseAPIKey)
    }

    func currentIDToken() async throws -> String {
        var creds = try loadCredentials()

        // Refresh if token expires within 5 minutes
        if creds.expiresAt.timeIntervalSinceNow < 300 {
            let refreshed = try await firebaseAuth.refreshToken(creds.firebaseRefreshToken)
            creds.firebaseIdToken = refreshed.idToken
            creds.firebaseRefreshToken = refreshed.refreshToken
            creds.expiresAt = Date().addingTimeInterval(TimeInterval(refreshed.expiresIn))
            try credentialStore.save(creds)
            lock.withLock { cachedCredentials = creds }
        }

        return creds.firebaseIdToken
    }

    private func loadCredentials() throws -> CLICredentials {
        if let cached = lock.withLock({ cachedCredentials }) {
            return cached
        }
        let creds = try credentialStore.load()
        lock.withLock { cachedCredentials = creds }
        return creds
    }

    func updateCredentials(_ credentials: CLICredentials) {
        lock.withLock { cachedCredentials = credentials }
    }
}

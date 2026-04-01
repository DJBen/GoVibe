import Foundation

/// Abstraction for obtaining a Firebase ID token.
/// The GUI host uses `FirebaseSDKTokenProvider`; the CLI uses a REST-based provider.
public protocol HostTokenProvider: Sendable {
    func currentIDToken() async throws -> String
}

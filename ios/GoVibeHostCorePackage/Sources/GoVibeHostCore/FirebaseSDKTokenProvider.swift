@preconcurrency import FirebaseAuth
import Foundation

/// Default `HostTokenProvider` for the GUI host app — wraps `Auth.auth().currentUser`.
public struct FirebaseSDKTokenProvider: HostTokenProvider {
    public init() {}

    public func currentIDToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw HostAPIError.notAuthenticated
        }
        return try await user.getIDTokenResult().token
    }
}

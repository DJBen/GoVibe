import Foundation

/// Configuration for CLI authentication, loaded from environment variables
/// with fallback to Info.plist build-time values.
struct CLIAuthConfig {
    let firebaseAPIKey: String
    let googleDeviceClientID: String
    let googleDeviceClientSecret: String

    var isValid: Bool {
        !firebaseAPIKey.isEmpty && !googleDeviceClientID.isEmpty && !googleDeviceClientSecret.isEmpty
    }

    init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) {
        self.firebaseAPIKey = Self.resolve(
            key: "GOVIBE_FIREBASE_API_KEY", env: env, bundle: bundle
        )
        self.googleDeviceClientID = Self.resolve(
            key: "GOVIBE_GOOGLE_DEVICE_CLIENT_ID", env: env, bundle: bundle
        )
        self.googleDeviceClientSecret = Self.resolve(
            key: "GOVIBE_GOOGLE_DEVICE_CLIENT_SECRET", env: env, bundle: bundle
        )
    }

    private static func resolve(key: String, env: [String: String], bundle: Bundle) -> String {
        if let value = env[key], !value.isEmpty {
            return value
        }
        let bundleValue = bundle.object(forInfoDictionaryKey: key) as? String ?? ""
        let trimmed = bundleValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("DUMMY_") ? "" : trimmed
    }
}

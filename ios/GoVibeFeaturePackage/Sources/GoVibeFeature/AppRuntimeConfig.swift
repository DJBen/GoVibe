import Foundation

enum AppRuntimeConfig {
    private enum Keys {
        static let apiBase = "GOVIBE_API_BASE"
        static let relayWebSocketBase = "GOVIBE_RELAY_WS_BASE"
    }

    static let apiBaseURL: URL = {
        let raw = requiredString(for: Keys.apiBase, expectedExample: "https://<region>-<project>.cloudfunctions.net/api")
        guard let url = URL(string: raw) else {
            fatalError("Invalid \(Keys.apiBase) URL: \(raw)")
        }
        return url
    }()

    static let relayWebSocketBase: String = {
        requiredString(for: Keys.relayWebSocketBase, expectedExample: "wss://<service>.<region>.run.app/relay")
    }()

    private static func requiredString(for key: String, expectedExample: String) -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.hasPrefix("DUMMY_") {
            fatalError("Set \(key) in ios/Config/Shared.xcconfig (current: \(trimmed.isEmpty ? "<empty>" : trimmed)). Example: \(expectedExample)")
        }
        return trimmed
    }
}

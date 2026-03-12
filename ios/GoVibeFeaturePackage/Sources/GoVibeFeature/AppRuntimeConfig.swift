import Foundation

enum AppRuntimeConfig {
    private enum Keys {
        static let gcpRegion = "GOVIBE_GCP_REGION"
        static let gcpProjectID = "GOVIBE_GCP_PROJECT_ID"
        static let gcpRelayHost = "GOVIBE_GCP_RELAY_HOST"
    }

    static let apiBaseURL: URL = {
        let region = requiredConfiguredValue(for: Keys.gcpRegion, expectedExample: "us-west1")
        let projectID = requiredConfiguredValue(for: Keys.gcpProjectID, expectedExample: "my-project-id")
        let raw = "https://\(region)-\(projectID).cloudfunctions.net/api"
        guard let url = URL(string: raw) else {
            fatalError("Invalid assembled API URL: \(raw)")
        }
        return url
    }()

    static let relayWebSocketBase: String = {
        let relayHostRaw = requiredConfiguredValue(
            for: Keys.gcpRelayHost,
            expectedExample: "govibe-relay-xxxxx-uw.a.run.app"
        )
        let relayHost = normalizedRelayHost(from: relayHostRaw)
        guard !relayHost.isEmpty else {
            fatalError("Invalid \(Keys.gcpRelayHost): \(relayHostRaw)")
        }
        return "wss://\(relayHost)/relay"
    }()

    private static func configuredValue(for key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !trimmed.hasPrefix("DUMMY_") else {
            return nil
        }
        return trimmed
    }

    private static func requiredConfiguredValue(for key: String, expectedExample: String) -> String {
        if let value = configuredValue(for: key) {
            return value
        }
        let currentValue = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        fatalError("Set \(key) in ios/Config/Shared.xcconfig (current: \(currentValue.isEmpty ? "<empty>" : currentValue)). Example: \(expectedExample)")
    }

    private static func normalizedRelayHost(from input: String) -> String {
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
        return host.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

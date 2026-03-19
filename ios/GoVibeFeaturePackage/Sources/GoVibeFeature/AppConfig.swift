import Foundation
import Observation

@Observable
@MainActor
public final class AppConfig {
    public static let shared = AppConfig()

    public var gcpProjectID: String = ""
    public var gcpRegion: String = ""
    public var relayHost: String = ""

    private let defaults: UserDefaults
    private let bundle: Bundle

    private enum Keys {
        static let gcpProjectID = "GOVIBE_GCP_PROJECT_ID"
        static let gcpRegion = "GOVIBE_GCP_REGION"
        static let relayHost = "GOVIBE_GCP_RELAY_HOST"
    }

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
        load()
    }

    public var isValid: Bool {
        !gcpProjectID.isEmpty && !gcpRegion.isEmpty && !relayHost.isEmpty
    }

    public var apiBaseURL: URL? {
        guard isValid else { return nil }
        let raw = "https://\(gcpRegion)-\(gcpProjectID).cloudfunctions.net/api"
        return URL(string: raw)
    }

    public var relayWebSocketBase: String? {
        guard isValid else { return nil }
        let host = normalizedRelayHost(from: relayHost)
        guard !host.isEmpty else { return nil }
        return "wss://\(host)/relay"
    }

    public func load() {
        // GCP project/region: read from environment variables, then fall back to Info.plist
        let env = ProcessInfo.processInfo.environment
        let envID = env[Keys.gcpProjectID].flatMap { $0.isEmpty ? nil : $0 }
        let envRegion = env[Keys.gcpRegion].flatMap { $0.isEmpty ? nil : $0 }

        if let id = envID {
            self.gcpProjectID = id
        } else {
            let bundleID = bundle.object(forInfoDictionaryKey: Keys.gcpProjectID) as? String ?? ""
            let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.gcpProjectID = trimmed.hasPrefix("DUMMY_") ? "" : trimmed
        }

        if let region = envRegion {
            self.gcpRegion = region
        } else {
            let bundleRegion = bundle.object(forInfoDictionaryKey: Keys.gcpRegion) as? String ?? ""
            let trimmed = bundleRegion.trimmingCharacters(in: .whitespacesAndNewlines)
            self.gcpRegion = trimmed.hasPrefix("DUMMY_") ? "" : trimmed
        }

        // Relay host: UserDefaults first, then environment, then Info.plist
        if let savedRelay = defaults.string(forKey: Keys.relayHost), !savedRelay.isEmpty {
            self.relayHost = savedRelay
            return
        }

        if let envRelay = env[Keys.relayHost], !envRelay.isEmpty {
            self.relayHost = envRelay
            return
        }

        let bundleRelay = bundle.object(forInfoDictionaryKey: Keys.relayHost) as? String ?? ""
        let trimmedRelay = bundleRelay.trimmingCharacters(in: .whitespacesAndNewlines)
        self.relayHost = trimmedRelay.hasPrefix("DUMMY_") ? "" : trimmedRelay
    }

    public func save(relay: String) {
        self.relayHost = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(self.relayHost, forKey: Keys.relayHost)
    }

    public func reset() {
        defaults.removeObject(forKey: Keys.relayHost)
        load()
    }

    private func normalizedRelayHost(from input: String) -> String {
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

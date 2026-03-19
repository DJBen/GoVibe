import Foundation
import Observation

@Observable
@MainActor
public final class HostConfig {
    public static let shared = HostConfig()

    public var relayHost: String = ""
    public var gcpProjectID: String = ""
    public var gcpRegion: String = ""

    private let defaults: UserDefaults
    private let env: [String: String]
    private let bundle: Bundle

    private enum Keys {
        static let relayHost = "GOVIBE_RELAY_WS_BASE" // Env var
        static let relayHostEnv = "GOVIBE_GCP_RELAY_HOST" // Env var (New)
        static let relayHostPlist = "GOVIBE_GCP_RELAY_HOST" // Plist
        static let relayHostDefaults = "GOVIBE_GCP_RELAY_HOST" // UserDefaults
        static let gcpProjectID = "GOVIBE_GCP_PROJECT_ID"
        static let gcpRegion = "GOVIBE_GCP_REGION"
    }

    init(
        defaults: UserDefaults = .standard,
        env: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) {
        self.defaults = defaults
        self.env = env
        self.bundle = bundle
        load()
    }

    public var isValid: Bool {
        !relayHost.isEmpty
    }

    public var relayWebSocketBase: String? {
        guard isValid else { return nil }
        let host = normalizedRelayHost(from: relayHost)
        guard !host.isEmpty else { return nil }
        return "wss://\(host)/relay"
    }

    public var apiBaseURL: URL? {
        guard !gcpProjectID.isEmpty, !gcpRegion.isEmpty else { return nil }
        return URL(string: "https://\(gcpRegion)-\(gcpProjectID).cloudfunctions.net/api")
    }

    public func load() {
        if let projectID = env[Keys.gcpProjectID], !projectID.isEmpty {
            gcpProjectID = projectID
        } else {
            let bundleValue = bundle.object(forInfoDictionaryKey: Keys.gcpProjectID) as? String ?? ""
            let trimmed = bundleValue.trimmingCharacters(in: .whitespacesAndNewlines)
            gcpProjectID = trimmed.hasPrefix("DUMMY_") ? "" : trimmed
        }

        if let region = env[Keys.gcpRegion], !region.isEmpty {
            gcpRegion = region
        } else {
            let bundleValue = bundle.object(forInfoDictionaryKey: Keys.gcpRegion) as? String ?? ""
            let trimmed = bundleValue.trimmingCharacters(in: .whitespacesAndNewlines)
            gcpRegion = trimmed.hasPrefix("DUMMY_") ? "" : trimmed
        }

        // 1. Try UserDefaults
        if let relay = defaults.string(forKey: Keys.relayHostDefaults), !relay.isEmpty {
            self.relayHost = relay
            return
        }

        // 2. Try Environment Variable (for dev/scripting)
        if let relay = env[Keys.relayHost], !relay.isEmpty {
            self.relayHost = relay
            return
        }

        if let relay = env[Keys.relayHostEnv], !relay.isEmpty {
            self.relayHost = relay
            return
        }

        // 3. Try Info.plist / Bundle
        let bundleRelay = bundle.object(forInfoDictionaryKey: Keys.relayHostPlist) as? String
        self.relayHost = (bundleRelay ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        if self.relayHost.hasPrefix("DUMMY_") { self.relayHost = "" }
    }

    public func save(relay: String) {
        self.relayHost = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(self.relayHost, forKey: Keys.relayHostDefaults)
    }

    public func reset() {
        defaults.removeObject(forKey: Keys.relayHostDefaults)
        load()
    }

    /// Returns the normalized hostname from a relay URL string, or nil if the input is empty/invalid.
    /// Strips scheme (wss://, https://, etc.) and path components.
    /// Mirrors the validation logic used by the iOS companion app.
    public static func normalizedRelayHost(from input: String) -> String? {
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
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

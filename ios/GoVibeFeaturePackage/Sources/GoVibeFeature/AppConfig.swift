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
        // 1. Try UserDefaults
        let defaultsID = defaults.string(forKey: Keys.gcpProjectID)
        let defaultsRegion = defaults.string(forKey: Keys.gcpRegion)
        let defaultsRelay = defaults.string(forKey: Keys.relayHost)

        if let id = defaultsID, !id.isEmpty,
           let region = defaultsRegion, !region.isEmpty,
           let relay = defaultsRelay, !relay.isEmpty {
            self.gcpProjectID = id
            self.gcpRegion = region
            self.relayHost = relay
            return
        }

        // 2. Try Info.plist / Bundle
        let bundleID = bundle.object(forInfoDictionaryKey: Keys.gcpProjectID) as? String
        let bundleRegion = bundle.object(forInfoDictionaryKey: Keys.gcpRegion) as? String
        let bundleRelay = bundle.object(forInfoDictionaryKey: Keys.relayHost) as? String

        self.gcpProjectID = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.gcpRegion = (bundleRegion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.relayHost = (bundleRelay ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Filter out dummy values if any
        if self.gcpProjectID.hasPrefix("DUMMY_") { self.gcpProjectID = "" }
        if self.gcpRegion.hasPrefix("DUMMY_") { self.gcpRegion = "" }
        if self.relayHost.hasPrefix("DUMMY_") { self.relayHost = "" }
    }

    public func save(projectID: String, region: String, relay: String) {
        self.gcpProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.gcpRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
        self.relayHost = relay.trimmingCharacters(in: .whitespacesAndNewlines)

        defaults.set(self.gcpProjectID, forKey: Keys.gcpProjectID)
        defaults.set(self.gcpRegion, forKey: Keys.gcpRegion)
        defaults.set(self.relayHost, forKey: Keys.relayHost)
    }

    public func reset() {
        defaults.removeObject(forKey: Keys.gcpProjectID)
        defaults.removeObject(forKey: Keys.gcpRegion)
        defaults.removeObject(forKey: Keys.relayHost)
        load() // Reloads from Bundle if available, or clears
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

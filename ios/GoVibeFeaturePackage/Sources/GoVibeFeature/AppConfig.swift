import Foundation
import Observation

@Observable
@MainActor
public final class AppConfig {
    public static let shared = AppConfig()

    public var gcpProjectID: String = ""
    public var gcpRegion: String = ""
    public var relayHost: String = ""

    private let bundle: Bundle

    private enum Keys {
        static let gcpProjectID = "GOVIBE_GCP_PROJECT_ID"
        static let gcpRegion = "GOVIBE_GCP_REGION"
        static let relayHost = "GOVIBE_GCP_RELAY_HOST"
    }

    init(bundle: Bundle = .main) {
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
        let env = ProcessInfo.processInfo.environment

        // GCP project: environment variable, then Info.plist
        if let id = env[Keys.gcpProjectID], !id.isEmpty {
            self.gcpProjectID = id
        } else {
            let bundleID = bundle.object(forInfoDictionaryKey: Keys.gcpProjectID) as? String ?? ""
            let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.gcpProjectID = trimmed.hasPrefix("DUMMY_") ? "" : trimmed
        }

        // GCP region: environment variable, then Info.plist
        if let region = env[Keys.gcpRegion], !region.isEmpty {
            self.gcpRegion = region
        } else {
            let bundleRegion = bundle.object(forInfoDictionaryKey: Keys.gcpRegion) as? String ?? ""
            let trimmed = bundleRegion.trimmingCharacters(in: .whitespacesAndNewlines)
            self.gcpRegion = trimmed.hasPrefix("DUMMY_") ? "" : trimmed
        }

        // Relay host: environment variable, then Info.plist
        if let envRelay = env[Keys.relayHost], !envRelay.isEmpty {
            self.relayHost = envRelay
            return
        }

        let bundleRelay = bundle.object(forInfoDictionaryKey: Keys.relayHost) as? String ?? ""
        let trimmedRelay = bundleRelay.trimmingCharacters(in: .whitespacesAndNewlines)
        self.relayHost = trimmedRelay.hasPrefix("DUMMY_") ? "" : trimmedRelay
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

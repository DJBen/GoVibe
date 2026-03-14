import Foundation

public enum HostRuntimeDefaults {
    public static func makeSettings(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HostSettings {
        let hostId = environment["GOVIBE_HOST_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultHostID = hostId?.isEmpty == false ? hostId! : UUID().uuidString
        return HostSettings(
            hostId: defaultHostID,
            relayBase: resolveRelayBase(bundle: bundle, environment: environment),
            defaultShellPath: environment["GOVIBE_SHELL"] ?? environment["SHELL"] ?? "/bin/zsh"
        )
    }

    public static func resolveRelayBase(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let relay = environment["GOVIBE_RELAY_WS_BASE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !relay.isEmpty {
            return relay
        }

        let host = (bundle.object(forInfoDictionaryKey: "GOVIBE_GCP_RELAY_HOST") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !host.isEmpty, !host.hasPrefix("DUMMY_") {
            return "wss://\(normalizedRelayHost(from: host))/relay"
        }

        return ""
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

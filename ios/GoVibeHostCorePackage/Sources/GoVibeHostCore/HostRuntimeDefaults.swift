import Foundation

@MainActor
public enum HostRuntimeDefaults {
    public static func makeSettings(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HostSettings {
        let hostId = environment["GOVIBE_HOST_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultHostID = hostId?.isEmpty == false ? hostId! : UUID().uuidString
        return HostSettings(
            hostId: defaultHostID,
            relayBase: HostConfig.shared.relayWebSocketBase ?? "",
            defaultShellPath: environment["GOVIBE_SHELL"] ?? environment["SHELL"] ?? "/bin/zsh"
        )
    }

    public static func resolveRelayBase(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        return HostConfig.shared.relayWebSocketBase ?? ""
    }
}

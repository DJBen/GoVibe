import Foundation

@MainActor
public enum HostRuntimeDefaults {
    public static func makeSettings(
        userID: String? = nil,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HostSettings {
        return HostSettings(
            hostId: HostMachineIdentity.resolveHostID(userID: userID, environment: environment),
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

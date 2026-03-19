import Foundation

@MainActor
public enum HostRuntimeDefaults {
    public static func makeSettings(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HostSettings {
        return HostSettings(
            hostId: HostMachineIdentity.resolveHostID(environment: environment),
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

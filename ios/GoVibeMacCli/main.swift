import ArgumentParser
import Foundation

struct GoVibeMacCli: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "GoVibe Mac relay agent — bridges a local PTY to the GoVibe relay."
    )

    @Option(help: "Shell executable.")
    var shell: String = ProcessInfo.processInfo.environment["GOVIBE_SHELL"] ?? "/bin/zsh"

    @Option(help: "Relay WebSocket base URL (or set GOVIBE_RELAY_WS_BASE env var).")
    var relay: String = ProcessInfo.processInfo.environment["GOVIBE_RELAY_WS_BASE"] ?? ""

    @Option(name: .customLong("device-id"), help: "Room / device ID for the relay.")
    var deviceId: String = ProcessInfo.processInfo.environment["GOVIBE_MAC_DEVICE_ID"] ?? "mac-demo-01"

    @Option(name: .customLong("session-name"), help: "tmux session name (defaults to device-id).")
    var sessionName: String?

    mutating func run() throws {
        guard !relay.isEmpty else {
            throw ValidationError("Relay URL is required. Pass --relay or set GOVIBE_RELAY_WS_BASE.")
        }

        let resolvedSessionName = sessionName ?? deviceId

        let logger = Logger()
        logger.info("Starting GoVibeMacCli")
        logger.info("Device ID: \(deviceId)")
        logger.info("Relay: \(relay)")
        logger.info("tmux session: \(resolvedSessionName)")

        let pty = PtySession(shellPath: shell, tmuxSessionName: resolvedSessionName, logger: logger)
        let coordinator = SessionCoordinator(
            macDeviceId: deviceId,
            pty: pty,
            logger: logger,
            relayBase: relay
        )

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let signalQueue = DispatchQueue(label: "dev.govibe.maccli.signals")
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        sigintSource.setEventHandler {
            logger.info("Received SIGINT, stopping")
            coordinator.stop()
        }
        sigtermSource.setEventHandler {
            logger.info("Received SIGTERM, stopping")
            coordinator.stop()
        }
        sigintSource.resume()
        sigtermSource.resume()

        try coordinator.runForever()
    }
}

GoVibeMacCli.main()

import AppKit
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

    @Option(name: .customLong("mode"), help: "Operating mode: 'terminal' (default) or 'simulator'.")
    var mode: String = "terminal"

    mutating func run() throws {
        guard !relay.isEmpty else {
            throw ValidationError("Relay URL is required. Pass --relay or set GOVIBE_RELAY_WS_BASE.")
        }

        let logger = Logger()
        logger.info("Starting GoVibeMacCli")
        logger.info("Device ID: \(deviceId)")
        logger.info("Relay: \(relay)")
        logger.info("Mode: \(mode)")

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signalQueue = DispatchQueue(label: "dev.govibe.maccli.signals")

        if mode == "simulator" {
            // Initialize NSApplication on the main thread before any ScreenCaptureKit work.
            // CGS (CoreGraphics Session / window server connection) is required by SCContentFilter
            // and must be established from the main thread.
            NSApplication.shared.setActivationPolicy(.prohibited)
            logger.info("NSApplication initialized (CGS ready)")

            let coordinator = SimulatorSessionCoordinator(
                macDeviceId: deviceId,
                logger: logger,
                relayBase: relay
            )
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
        } else {
            let resolvedSessionName = sessionName ?? deviceId
            logger.info("tmux session: \(resolvedSessionName)")
            let pty = PtySession(shellPath: shell, tmuxSessionName: resolvedSessionName, logger: logger)
            let coordinator = SessionCoordinator(
                macDeviceId: deviceId,
                pty: pty,
                logger: logger,
                relayBase: relay
            )
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
}

GoVibeMacCli.main()

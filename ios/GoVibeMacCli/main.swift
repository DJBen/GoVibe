import AppKit
import ArgumentParser
import Foundation

struct GoVibeMacCli: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "GoVibeMacCli",
        abstract: "GoVibe Mac relay agent — bridges local sessions to the GoVibe relay.",
        subcommands: [Terminal.self, Simulator.self]
    )
}

// MARK: - Shared options

struct SharedOptions: ParsableArguments {
    @Option(help: "Relay WebSocket base URL (or set GOVIBE_RELAY_WS_BASE).")
    var relay: String = ProcessInfo.processInfo.environment["GOVIBE_RELAY_WS_BASE"] ?? ""

    @Option(name: .customLong("device-id"), help: "Room / device ID for the relay.")
    var deviceId: String = ProcessInfo.processInfo.environment["GOVIBE_MAC_DEVICE_ID"] ?? "mac-demo-01"

    func validated() throws -> (relay: String, deviceId: String) {
        guard !relay.isEmpty else {
            throw ValidationError("Relay URL is required. Pass --relay or set GOVIBE_RELAY_WS_BASE.")
        }
        return (relay, deviceId)
    }
}

// MARK: - Terminal subcommand

struct Terminal: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mirror a local shell/tmux session to the relay."
    )

    @OptionGroup var shared: SharedOptions

    @Option(help: "Shell executable.")
    var shell: String = ProcessInfo.processInfo.environment["GOVIBE_SHELL"] ?? "/bin/zsh"

    @Option(name: .customLong("session-name"), help: "tmux session name (defaults to device-id).")
    var sessionName: String?

    mutating func run() throws {
        let (relay, deviceId) = try shared.validated()
        let logger = Logger()
        logger.info("Starting GoVibeMacCli")
        logger.info("Device ID: \(deviceId)")
        logger.info("Relay: \(relay)")
        logger.info("Mode: terminal")

        let resolvedSessionName = sessionName ?? deviceId
        logger.info("tmux session: \(resolvedSessionName)")

        let pty = PtySession(shellPath: shell, tmuxSessionName: resolvedSessionName, logger: logger)
        let coordinator = SessionCoordinator(
            macDeviceId: deviceId,
            pty: pty,
            logger: logger,
            relayBase: relay
        )
        setupSignalHandlers(logger: logger, stop: coordinator.stop)
        try coordinator.runForever()
    }
}

// MARK: - Simulator subcommand

struct Simulator: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stream the iOS Simulator screen to the relay and relay touch/button events back."
    )

    @OptionGroup var shared: SharedOptions

    @Option(name: .customLong("udid"),
            help: "Simulator device UDID to capture (default: first booted device).")
    var udid: String?

    mutating func run() throws {
        let (relay, deviceId) = try shared.validated()
        let logger = Logger()
        logger.info("Starting GoVibeMacCli")
        logger.info("Device ID: \(deviceId)")
        logger.info("Relay: \(relay)")
        logger.info("Mode: simulator")
        if let udid { logger.info("Target UDID: \(udid)") }

        // NSApplication must be initialized on the main thread before any
        // ScreenCaptureKit work so the CGS (window server) connection is ready.
        NSApplication.shared.setActivationPolicy(.prohibited)
        logger.info("NSApplication initialized (CGS ready)")

        let coordinator = SimulatorSessionCoordinator(
            macDeviceId: deviceId,
            logger: logger,
            relayBase: relay,
            preferredUDID: udid
        )
        setupSignalHandlers(logger: logger, stop: coordinator.stop)
        try coordinator.runForever()
    }
}

// MARK: - Helpers

private var retainedSignalSources: [DispatchSourceSignal] = []

private func setupSignalHandlers(logger: Logger, stop: @escaping () -> Void) {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let queue = DispatchQueue(label: "dev.govibe.maccli.signals")
    let sigint  = DispatchSource.makeSignalSource(signal: SIGINT,  queue: queue)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
    sigint.setEventHandler  { logger.info("Received SIGINT, stopping");  stop() }
    sigterm.setEventHandler { logger.info("Received SIGTERM, stopping"); stop() }
    sigint.resume()
    sigterm.resume()
    retainedSignalSources = [sigint, sigterm]
}

GoVibeMacCli.main()

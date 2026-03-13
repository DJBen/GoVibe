import Foundation

final class SimulatorSessionCoordinator {
    private let macDeviceId: String
    private let logger: Logger
    private let bridge: SignalBridge
    private let simulatorBridge: SimulatorBridge
    private let relayBase: String
    private var running = true
    private var heartbeatTimer: DispatchSourceTimer?
    private var retirementSent = false
    // Latest sim_info to broadcast — starts as preliminary stub, upgraded to real
    // dimensions once capture starts. Always sent on every heartbeat so any
    // newly-joining iOS peer gets it within one heartbeat interval.
    private var latestSimInfo: SimInfoPayload?

    init(macDeviceId: String, logger: Logger, relayBase: String) {
        self.macDeviceId = macDeviceId
        self.logger = logger
        self.bridge = SignalBridge(logger: logger)
        self.simulatorBridge = SimulatorBridge(logger: logger)
        self.relayBase = relayBase
    }

    func runForever() throws {
        // Build preliminary sim_info (stub dimensions) so iOS can switch to
        // SimulatorView while the async capture pipeline is still starting.
        if let device = simulatorBridge.findBootedSimulator() {
            latestSimInfo = SimInfoPayload(
                deviceName: device.name,
                udid: device.udid,
                screenWidth: 390,
                screenHeight: 844,
                scale: 1.0,
                fps: 30
            )
            logger.info("Pre-cached simulator: \(device.name) (\(device.udid))")
        } else {
            logger.info("No booted simulator found during pre-cache (will retry on peer join)")
        }

        // When capture starts, upgrade latestSimInfo to the real window dimensions
        // and broadcast immediately.
        simulatorBridge.onSimInfo = { [weak self] info in
            self?.latestSimInfo = info
            self?.bridge.sendSimInfo(info)
        }

        // Forward binary H.264 frames to relay.
        simulatorBridge.onBinaryFrame = { [weak self] data in
            self?.bridge.sendBinaryFrame(data)
        }

        // Wire touch/button messages from relay to injector.
        bridge.onSimTouch = { [weak self] phase, x, y in
            self?.simulatorBridge.injectTouch(phase: phase, x: x, y: y)
        }
        bridge.onSimPinch = { [weak self] phase, centerX, centerY, scale in
            self?.simulatorBridge.injectPinch(phase: phase, centerX: centerX,
                                               centerY: centerY, scale: scale)
        }
        bridge.onSimButton = { [weak self] action in
            self?.simulatorBridge.injectButton(action: action)
        }
        bridge.onSimKeyframeRequest = { [weak self] in
            self?.simulatorBridge.forceKeyframe()
        }

        // When iOS joins, immediately push latestSimInfo so it switches to
        // SimulatorView without waiting for the next heartbeat. Also start/retry
        // capture (idempotent — no-op if already running).
        bridge.onPeerJoined = { [weak self] in
            guard let self else { return }
            self.logger.info("Peer joined — sending sim_info")
            if let info = self.latestSimInfo {
                self.bridge.sendSimInfo(info)
            }
            let udid = self.latestSimInfo?.udid
            Task { await self.simulatorBridge.startCapture(preferredUDID: udid) }
        }

        bridge.start(room: macDeviceId, relayBase: relayBase)
        startHeartbeat()

        // Start capture immediately on the cooperative thread pool — do NOT use
        // @MainActor here. The main thread is about to block on Thread.sleep so
        // a @MainActor task would never execute (DispatchQueue.main can't drain
        // while the main thread is sleeping). NSApplication is already initialised
        // in main.swift so SCK APIs are safe to call from a background task.
        let preferredUDID = latestSimInfo?.udid
        Task { await self.simulatorBridge.startCapture(preferredUDID: preferredUDID) }

        while running {
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.bridge.sendPeerHeartbeat()
            // Always re-broadcast the latest sim_info so any connected iOS peer
            // has it (covers the case where iOS reconnects mid-session).
            if let info = self.latestSimInfo {
                self.bridge.sendSimInfo(info)
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func sendPeerRetiredIfNeeded(reason: String) {
        guard !retirementSent else { return }
        retirementSent = true
        bridge.sendPeerRetiredSync(reason: reason)
    }

    func stop() {
        running = false
        simulatorBridge.stopCapture()
        sendPeerRetiredIfNeeded(reason: "stopped")
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
}

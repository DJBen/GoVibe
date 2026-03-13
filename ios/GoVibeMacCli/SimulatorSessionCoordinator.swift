import Foundation

final class SimulatorSessionCoordinator {
    private static let peerStaleTimeout: TimeInterval = 10

    private let macDeviceId: String
    private let logger: Logger
    private let bridge: SignalBridge
    private let simulatorBridge: SimulatorBridge
    private let relayBase: String
    private var running = true
    private var heartbeatTimer: DispatchSourceTimer?
    private var retirementSent = false
    private var hasPeer = false
    private var lastPeerActivityAt: Date?
    // Latest sim_info to broadcast — starts as preliminary stub, upgraded to real
    // dimensions once capture starts. Always sent on every heartbeat so any
    // newly-joining iOS peer gets it within one heartbeat interval.
    private var latestSimInfo: SimInfoPayload?

    private let preferredUDID: String?

    init(macDeviceId: String, logger: Logger, relayBase: String,
         preferredUDID: String? = nil) {
        self.macDeviceId = macDeviceId
        self.logger = logger
        self.bridge = SignalBridge(logger: logger)
        self.simulatorBridge = SimulatorBridge(logger: logger)
        self.relayBase = relayBase
        self.preferredUDID = preferredUDID
    }

    func runForever() throws {
        // Build preliminary sim_info (stub dimensions) so iOS can switch to
        // SimulatorView while the async capture pipeline is still starting.
        if let device = simulatorBridge.findBootedSimulator(preferredUDID: preferredUDID) {
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

        // Forward binary H.264 frames to relay only while a peer is connected.
        simulatorBridge.onBinaryFrame = { [weak self] data in
            guard let self, self.hasPeer else { return }
            self.bridge.sendBinaryFrame(data)
        }

        // Wire cursor/click/button messages from relay to injector.
        bridge.onSimCursorMove = { [weak self] dx, dy in
            self?.recordPeerActivity()
            self?.simulatorBridge.injectCursorMove(dx: dx, dy: dy)
        }
        bridge.onSimClick = { [weak self] clickCount in
            self?.recordPeerActivity()
            self?.simulatorBridge.injectClick(clickCount: clickCount)
        }
        bridge.onSimButton = { [weak self] action in
            self?.recordPeerActivity()
            self?.simulatorBridge.injectButton(action: action)
        }
        bridge.onSimKeyframeRequest = { [weak self] in
            self?.recordPeerActivity()
            self?.simulatorBridge.forceKeyframe()
        }
        bridge.onPeerHeartbeat = { [weak self] in
            self?.recordPeerActivity()
        }

        // When iOS joins, immediately push latestSimInfo so it switches to
        // SimulatorView without waiting for the next heartbeat. Also start/retry
        // capture (idempotent — no-op if already running).
        bridge.onPeerJoined = { [weak self] in
            guard let self else { return }
            self.recordPeerActivity()
            self.logger.info("Peer joined — sending sim_info")
            if let info = self.latestSimInfo {
                self.bridge.sendSimInfo(info)
            }
            Task { await self.simulatorBridge.startCapture(
                preferredUDID: self.preferredUDID ?? self.latestSimInfo?.udid
            ) }
        }

        bridge.onPeerLeft = { [weak self] in
            guard let self else { return }
            self.markPeerOffline(reason: "Peer left")
        }

        bridge.start(room: macDeviceId, relayBase: relayBase)
        startHeartbeat()

        // Start capture immediately on the cooperative thread pool — do NOT use
        // @MainActor here. The main thread is about to block on Thread.sleep so
        // a @MainActor task would never execute (DispatchQueue.main can't drain
        // while the main thread is sleeping). NSApplication is already initialised
        // in main.swift so SCK APIs are safe to call from a background task.
        Task { await self.simulatorBridge.startCapture(
            preferredUDID: preferredUDID ?? latestSimInfo?.udid
        ) }

        while running {
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.checkPeerFreshness()
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

    private func recordPeerActivity() {
        let wasOffline = !hasPeer
        hasPeer = true
        lastPeerActivityAt = Date()
        if wasOffline {
            logger.info("Peer activity detected — resuming frame forwarding")
            // If early startup frames were dropped while no peer was marked live,
            // force a fresh IDR (with SPS/PPS) so iOS can always decode immediately.
            simulatorBridge.forceKeyframe()
            if let info = latestSimInfo {
                bridge.sendSimInfo(info)
            }
        }
    }

    private func checkPeerFreshness() {
        guard hasPeer, let lastPeerActivityAt else { return }
        let staleSeconds = Date().timeIntervalSince(lastPeerActivityAt)
        if staleSeconds > Self.peerStaleTimeout {
            markPeerOffline(reason: "Peer heartbeat timed out (\(Int(staleSeconds))s) — pausing frame forwarding")
        }
    }

    private func markPeerOffline(reason: String) {
        guard hasPeer || lastPeerActivityAt != nil else { return }
        hasPeer = false
        lastPeerActivityAt = nil
        logger.info("\(reason)")
    }

    func stop() {
        running = false
        simulatorBridge.stopCapture()
        sendPeerRetiredIfNeeded(reason: "stopped")
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
}

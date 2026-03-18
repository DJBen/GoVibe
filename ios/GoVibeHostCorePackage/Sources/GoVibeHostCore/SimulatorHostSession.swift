import AppKit
import Foundation

public final class SimulatorHostSession: @unchecked Sendable, ManagedHostRuntime {
    private static let peerStaleTimeout: TimeInterval = 10

    private let macDeviceId: String
    private let logger: HostLogger
    private let bridge: RelayTransport
    private let simulatorBridge: SimulatorBridge
    private let relayBase: String
    private let eventHandler: @Sendable (HostSessionRuntimeEvent) -> Void

    private var heartbeatTimer: DispatchSourceTimer?
    private var retirementSent = false
    private var hasPeer = false
    private var lastPeerActivityAt: Date?
    private var latestSimInfo: SimInfoPayload?
    private let preferredUDID: String?
    private var stopSignalSent = false
    private let stopSemaphore = DispatchSemaphore(value: 0)

    public init(
        hostId: String,
        config: SimulatorSessionConfig,
        relayBase: String,
        logger: HostLogger,
        eventHandler: @escaping @Sendable (HostSessionRuntimeEvent) -> Void = { _ in }
    ) {
        self.macDeviceId = config.sessionId
        self.logger = logger
        self.bridge = RelayTransport(logger: logger)
        self.simulatorBridge = SimulatorBridge(logger: logger)
        self.relayBase = relayBase
        self.preferredUDID = config.preferredUDID
        self.eventHandler = eventHandler
    }

    public func start() {
        eventHandler(.stateChanged(.starting, nil, nil))

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

        simulatorBridge.onSimInfo = { [weak self] info in
            self?.latestSimInfo = info
            self?.bridge.sendSimInfo(info)
        }
        simulatorBridge.onBinaryFrame = { [weak self] data in
            guard let self, self.hasPeer else { return }
            self.bridge.sendBinaryFrame(data)
        }

        bridge.onSimCursorMove = { [weak self] dx, dy in
            self?.recordPeerActivity()
            self?.simulatorBridge.injectCursorMove(dx: dx, dy: dy)
        }
        bridge.onSimClick = { [weak self] button, clickCount in
            self?.recordPeerActivity()
            self?.simulatorBridge.injectClick(button: button, clickCount: clickCount)
        }
        bridge.onSimScroll = { [weak self] dx, dy in
            self?.recordPeerActivity()
            self?.simulatorBridge.injectScroll(dx: dx, dy: dy)
        }
        bridge.onSimButton = { [weak self] action in
            self?.recordPeerActivity()
            self?.simulatorBridge.injectButton(action: action)
        }
        bridge.onSimKeyframeRequest = { [weak self] in
            self?.recordPeerActivity()
            self?.simulatorBridge.forceKeyframe()
        }
        bridge.onSimDragBegin = { [weak self] in
            self?.recordPeerActivity()
            self?.simulatorBridge.injectDragBegin()
        }
        bridge.onSimDragMove = { [weak self] dx, dy in
            self?.recordPeerActivity()
            self?.simulatorBridge.injectDragMove(dx: dx, dy: dy)
        }
        bridge.onSimDragEnd = { [weak self] in
            self?.recordPeerActivity()
            self?.simulatorBridge.injectDragEnd()
        }
        bridge.onPeerHeartbeat = { [weak self] in
            self?.recordPeerActivity()
        }
        bridge.onPeerJoined = { [weak self] in
            guard let self else { return }
            self.recordPeerActivity()
            self.logger.info("Peer joined — sending sim_info")
            if let info = self.latestSimInfo {
                self.bridge.sendSimInfo(info)
            }
            DispatchQueue.main.async {
                self.simulatorBridge.focusForPeerJoin()
            }
            Task { await self.simulatorBridge.startCapture(preferredUDID: self.preferredUDID ?? self.latestSimInfo?.udid) }
        }
        bridge.onPeerLeft = { [weak self] in
            self?.markPeerOffline(reason: "Peer left")
        }

        bridge.start(room: macDeviceId, relayBase: relayBase)
        startHeartbeat()
        eventHandler(.stateChanged(.waitingForPeer, nil, nil))

        Task { await self.simulatorBridge.startCapture(preferredUDID: preferredUDID ?? latestSimInfo?.udid) }
    }

    public func runUntilStopped() {
        start()
        waitUntilStopped()
    }

    public func waitUntilStopped() {
        stopSemaphore.wait()
    }

    public func stop() {
        simulatorBridge.stopCapture()
        sendPeerRetiredIfNeeded(reason: "stopped")
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        bridge.stop()
        eventHandler(.stateChanged(.stopped, lastPeerActivityAt, nil))
        signalStopIfNeeded()
    }

    private func signalStopIfNeeded() {
        guard !stopSignalSent else { return }
        stopSignalSent = true
        stopSemaphore.signal()
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.checkPeerFreshness()
            self.bridge.sendPeerHeartbeat(origin: "mac")
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
        eventHandler(.stateChanged(.running, lastPeerActivityAt, nil))
        if wasOffline {
            logger.info("Peer activity detected — resuming frame forwarding")
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
            markPeerOffline(reason: "Peer heartbeat timed out (\(Int(staleSeconds))s)")
        }
    }

    private func markPeerOffline(reason: String) {
        guard hasPeer || lastPeerActivityAt != nil else { return }
        hasPeer = false
        lastPeerActivityAt = nil
        logger.info("\(reason)")
        eventHandler(.stateChanged(.stale, nil, nil))
    }
}

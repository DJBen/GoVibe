import AppKit
import Foundation

public final class AppWindowHostSession: @unchecked Sendable, ManagedHostRuntime {
    private static let peerStaleTimeout: TimeInterval = 120

    private let hostId: String
    private let macDeviceId: String
    private let logger: HostLogger
    private let transport: RelayTransport
    private let bridge: AppWindowBridge
    private let relayBase: String
    private let eventHandler: @Sendable (HostSessionRuntimeEvent) -> Void

    private var heartbeatTimer: DispatchSourceTimer?
    private var retirementSent = false
    private var activePeerCount = 0
    private var lastPeerActivityAt: Date?
    private var latestWindowInfo: AppWindowInfoPayload?
    private var stopSignalSent = false
    private let stopSemaphore = DispatchSemaphore(value: 0)

    public init(
        hostId: String,
        config: AppWindowSessionConfig,
        relayBase: String,
        logger: HostLogger,
        eventHandler: @escaping @Sendable (HostSessionRuntimeEvent) -> Void = { _ in }
    ) {
        self.hostId = hostId
        self.macDeviceId = "\(hostId)-\(config.sessionId)"
        self.logger = logger
        self.transport = RelayTransport(logger: logger)
        self.bridge = AppWindowBridge(
            windowTitle: config.windowTitle,
            bundleIdentifier: config.bundleIdentifier,
            logger: logger
        )
        self.relayBase = relayBase
        self.eventHandler = eventHandler
    }

    public func start() {
        eventHandler(.stateChanged(.starting, nil, nil))

        bridge.onAppWindowInfo = { [weak self] info in
            self?.latestWindowInfo = info
            // Reactively send window info when it changes and peers are connected.
            if let self, self.activePeerCount > 0 {
                self.transport.sendAppWindowInfo(info)
            }
        }
        bridge.onBinaryFrame = { [weak self] data in
            guard let self, self.activePeerCount > 0 else { return }
            self.transport.sendBinaryFrame(data)
        }

        transport.onSimCursorMove = { [weak self] dx, dy in
            self?.recordPeerActivity()
            self?.bridge.injectCursorMove(dx: dx, dy: dy)
        }
        transport.onSimClick = { [weak self] button, clickCount in
            self?.recordPeerActivity()
            self?.bridge.injectClick(button: button, clickCount: clickCount)
        }
        transport.onSimScroll = { [weak self] dx, dy in
            self?.recordPeerActivity()
            self?.bridge.injectScroll(dx: dx, dy: dy)
        }
        transport.onSimKeyframeRequest = { [weak self] in
            self?.recordPeerActivity()
            self?.bridge.forceKeyframe()
        }
        transport.onSimDragBegin = { [weak self] in
            self?.recordPeerActivity()
            self?.bridge.injectDragBegin()
        }
        transport.onSimDragMove = { [weak self] dx, dy in
            self?.recordPeerActivity()
            self?.bridge.injectDragMove(dx: dx, dy: dy)
        }
        transport.onSimDragEnd = { [weak self] in
            self?.recordPeerActivity()
            self?.bridge.injectDragEnd()
        }
        // Peer liveness is detected via peer_joined/peer_left and real data
        // messages — no periodic heartbeat needed.
        transport.onPeerJoined = { [weak self] in
            guard let self else { return }
            let becameActive = self.recordPeerJoin()
            if becameActive {
                self.logger.info("Peer joined — starting app window capture")
                DispatchQueue.main.async {
                    self.bridge.focusForPeerJoin()
                }
                Task { await self.bridge.startCapture(relayTransport: self.transport) }
            }
        }
        transport.onPeerLeft = { [weak self] in
            self?.recordPeerLeave()
        }

        transport.start(room: macDeviceId, hostId: hostId, relayBase: relayBase)
        startPeerWatchdog()
        eventHandler(.stateChanged(.waitingForPeer, nil, nil))
    }

    public func runUntilStopped() {
        start()
        waitUntilStopped()
    }

    public func waitUntilStopped() {
        stopSemaphore.wait()
    }

    public func stop() {
        bridge.stopCapture()
        sendPeerRetiredIfNeeded(reason: "stopped")
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        transport.stop()
        eventHandler(.stateChanged(.stopped, lastPeerActivityAt, nil))
        signalStopIfNeeded()
    }

    private func signalStopIfNeeded() {
        guard !stopSignalSent else { return }
        stopSignalSent = true
        stopSemaphore.signal()
    }

    private func startPeerWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            self?.checkPeerFreshness()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func sendPeerRetiredIfNeeded(reason: String) {
        guard !retirementSent else { return }
        retirementSent = true
        transport.sendPeerRetiredSync(reason: reason)
    }

    private func recordPeerActivity() {
        lastPeerActivityAt = Date()
        eventHandler(.stateChanged(.running, lastPeerActivityAt, nil))
    }

    @discardableResult
    private func recordPeerJoin() -> Bool {
        let wasOffline = activePeerCount == 0
        activePeerCount += 1
        recordPeerActivity()
        if wasOffline {
            logger.info("Peer activity detected — resuming frame forwarding")
            bridge.forceKeyframe()
            if let info = latestWindowInfo {
                transport.sendAppWindowInfo(info)
            }
        }
        return wasOffline
    }

    private func recordPeerLeave() {
        activePeerCount = max(0, activePeerCount - 1)
        guard activePeerCount == 0 else {
            eventHandler(.stateChanged(.running, lastPeerActivityAt, nil))
            return
        }
        lastPeerActivityAt = nil
        logger.info("Last peer left")
        eventHandler(.stateChanged(.waitingForPeer, nil, nil))
    }

    private func checkPeerFreshness() {
        guard activePeerCount > 0, let lastPeerActivityAt else { return }
        let staleSeconds = Date().timeIntervalSince(lastPeerActivityAt)
        if staleSeconds > Self.peerStaleTimeout {
            markPeerOffline(reason: "Peer heartbeat timed out (\(Int(staleSeconds))s)")
        }
    }

    private func markPeerOffline(reason: String) {
        guard activePeerCount > 0 || lastPeerActivityAt != nil else { return }
        activePeerCount = 0
        lastPeerActivityAt = nil
        logger.info("\(reason)")
        eventHandler(.stateChanged(.stale, nil, nil))
    }
}

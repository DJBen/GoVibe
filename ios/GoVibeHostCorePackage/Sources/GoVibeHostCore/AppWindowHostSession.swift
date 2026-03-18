import AppKit
import Foundation

public final class AppWindowHostSession: @unchecked Sendable, ManagedHostRuntime {
    private static let peerStaleTimeout: TimeInterval = 10

    private let macDeviceId: String
    private let logger: HostLogger
    private let transport: RelayTransport
    private let bridge: AppWindowBridge
    private let relayBase: String
    private let eventHandler: @Sendable (HostSessionRuntimeEvent) -> Void

    private var heartbeatTimer: DispatchSourceTimer?
    private var retirementSent = false
    private var hasPeer = false
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
        self.macDeviceId = config.sessionId
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
        }
        bridge.onBinaryFrame = { [weak self] data in
            guard let self, self.hasPeer else { return }
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
        transport.onPeerHeartbeat = { [weak self] in
            self?.recordPeerActivity()
        }
        transport.onPeerJoined = { [weak self] in
            guard let self else { return }
            self.recordPeerActivity()
            self.logger.info("Peer joined — starting app window capture")
            DispatchQueue.main.async {
                self.bridge.focusForPeerJoin()
            }
            Task { await self.bridge.startCapture(relayTransport: self.transport) }
        }
        transport.onPeerLeft = { [weak self] in
            self?.markPeerOffline(reason: "Peer left")
        }

        transport.start(room: macDeviceId, relayBase: relayBase)
        startHeartbeat()
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

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.checkPeerFreshness()
            self.transport.sendPeerHeartbeat(origin: "mac")
            if let info = self.latestWindowInfo {
                self.transport.sendAppWindowInfo(info)
            }
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
        let wasOffline = !hasPeer
        hasPeer = true
        lastPeerActivityAt = Date()
        eventHandler(.stateChanged(.running, lastPeerActivityAt, nil))
        if wasOffline {
            logger.info("Peer activity detected — resuming frame forwarding")
            bridge.forceKeyframe()
            if let info = latestWindowInfo {
                transport.sendAppWindowInfo(info)
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

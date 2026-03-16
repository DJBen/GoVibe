import Foundation

public final class RelayTransport: @unchecked Sendable {
    private let logger: HostLogger
    private var wsTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let queue = DispatchQueue(label: "dev.govibe.host.transport", qos: .userInitiated)
    private var outboundQueue: [String] = []
    private var isSending = false
    private var reconnectScheduled = false
    private var socketGeneration: UInt64 = 0
    private var room: String?
    private var relayBase: String?
    private let maxQueuedMessages = 2000

    public var onInputData: ((Data) -> Void)?
    public var onResize: ((Int, Int) -> Void)?
    public var onScroll: ((Int) -> Void)?
    public var onScrollCancel: (() -> Void)?
    public var onPeerJoined: (() -> Void)?
    public var onPeerLeft: (() -> Void)?
    public var onPeerHeartbeat: (() -> Void)?
    public var onSimCursorMove: ((Double, Double) -> Void)?
    public var onSimClick: ((Int) -> Void)?
    public var onSimButton: ((String) -> Void)?
    public var onSimKeyframeRequest: (() -> Void)?
    public var onSimDragBegin: (() -> Void)?
    public var onSimDragMove: ((Double, Double) -> Void)?
    public var onSimDragEnd: (() -> Void)?

    public init(logger: HostLogger) {
        self.logger = logger
    }

    public func start(room: String, relayBase: String) {
        self.room = room
        self.relayBase = relayBase
        connect()
    }

    public func stop() {
        queue.sync {
            socketGeneration &+= 1
            outboundQueue.removeAll()
            isSending = false
            reconnectScheduled = false
            wsTask?.cancel(with: .goingAway, reason: nil)
            wsTask = nil
        }
    }

    private func connect() {
        guard let room, let relayBase else { return }
        guard var components = URLComponents(string: relayBase) else {
            logger.error("Invalid relay URL: \(relayBase)")
            return
        }
        components.queryItems = [URLQueryItem(name: "room", value: room)]

        guard let url = components.url else {
            logger.error("Failed to compose relay URL")
            return
        }

        logger.info("Connecting relay socket: \(url.absoluteString)")
        socketGeneration &+= 1
        let task = session.webSocketTask(with: url)
        task.resume()
        wsTask = task
        receiveLoop(generation: socketGeneration)
        flushOutboundQueue()
    }

    public func sendTerminalOutput(_ data: Data) {
        enqueueJSON([
            "type": "terminal_output",
            "encoding": "base64",
            "data": data.base64EncodedString(),
        ])
    }

    public func sendPaneProgram(_ name: String) {
        enqueueJSON([
            "type": "pane_program",
            "name": name,
        ])
    }

    public func sendPushNotify(event: String) {
        enqueueJSON(["type": "push_notify", "event": event])
    }

    public func sendSnapshot(_ data: Data) {
        let payload: [String: String] = [
            "type": "terminal_snapshot",
            "encoding": "base64",
            "data": data.base64EncodedString(),
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        queue.async {
            self.outboundQueue.removeAll()
            self.outboundQueue.insert(json, at: 0)
            self.flushOutboundQueueLocked()
        }
    }

    public func sendPeerHeartbeat(origin: String = "mac") {
        enqueueJSON(["type": "peer_heartbeat", "origin": origin])
    }

    public func sendSimInfo(_ payload: SimInfoPayload) {
        let dict: [String: Any] = [
            "type": "sim_info",
            "deviceName": payload.deviceName,
            "udid": payload.udid,
            "screenWidth": payload.screenWidth,
            "screenHeight": payload.screenHeight,
            "scale": payload.scale,
            "fps": payload.fps,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            logger.error("sendSimInfo: JSON serialization failed")
            return
        }
        queue.async {
            self.outboundQueue.append(json)
            self.flushOutboundQueueLocked()
        }
    }

    public func sendBinaryFrame(_ data: Data) {
        queue.async {
            guard let task = self.wsTask else { return }
            task.send(.data(data)) { [weak self] error in
                if let error {
                    self?.logger.error("Binary frame send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    public func sendPeerRetiredSync(reason: String, timeout: TimeInterval = 0.5) {
        let payload: [String: String] = [
            "type": "peer_retired",
            "reason": reason,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        // Best-effort shutdown signal. Do not block the caller on the socket callback,
        // otherwise UI-triggered stop actions can invert priority against the transport queue.
        queue.async {
            guard let task = self.wsTask else { return }
            task.send(.string(json)) { [weak self] error in
                if let error {
                    self?.logger.error("Relay send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func enqueueJSON(_ payload: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        queue.async {
            if self.outboundQueue.count >= self.maxQueuedMessages {
                self.outboundQueue.removeFirst(self.outboundQueue.count - self.maxQueuedMessages + 1)
            }
            self.outboundQueue.append(json)
            self.flushOutboundQueueLocked()
        }
    }

    private func flushOutboundQueue() {
        queue.async {
            self.flushOutboundQueueLocked()
        }
    }

    private func flushOutboundQueueLocked() {
        guard !isSending else { return }
        guard !outboundQueue.isEmpty else { return }
        guard let task = wsTask else { return }
        let generation = socketGeneration

        isSending = true
        let next = outboundQueue.removeFirst()
        task.send(.string(next)) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard generation == self.socketGeneration else { return }
                self.isSending = false
                if let error {
                    self.logger.error("Relay send failed: \(error.localizedDescription)")
                    self.outboundQueue.insert(next, at: 0)
                    self.scheduleReconnectLocked()
                    return
                }
                self.flushOutboundQueueLocked()
            }
        }
    }

    private func scheduleReconnectLocked() {
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        outboundQueue.removeAll()
        isSending = false
        socketGeneration &+= 1
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil

        queue.asyncAfter(deadline: .now() + 1.0) {
            self.reconnectScheduled = false
            self.connect()
        }
    }

    private func receiveLoop(generation: UInt64) {
        queue.async {
            guard let task = self.wsTask else { return }
            task.receive { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard generation == self.socketGeneration else { return }
                    switch result {
                    case .failure(let error):
                        self.logger.error("Relay receive failed: \(error.localizedDescription)")
                        self.scheduleReconnectLocked()
                    case .success(let message):
                        switch message {
                        case .string(let raw):
                            self.handleMessage(raw)
                        case .data(let data):
                            if let text = String(data: data, encoding: .utf8) {
                                self.handleMessage(text)
                            }
                        @unknown default:
                            break
                        }
                        self.receiveLoop(generation: generation)
                    }
                }
            }
        }
    }

    private func handleMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "peer_joined":
            onPeerJoined?()
        case "peer_left":
            onPeerLeft?()
        case "peer_heartbeat":
            let origin = (json["origin"] as? String)?.lowercased()
            if origin != "mac" {
                onPeerHeartbeat?()
            }
        case "terminal_input":
            if let encoding = json["encoding"] as? String,
               encoding.lowercased() == "base64",
               let encoded = json["data"] as? String,
               let payload = Data(base64Encoded: encoded) {
                logger.info("Relay input received (\(payload.count) bytes)")
                onInputData?(payload)
                return
            }
            if let text = json["text"] as? String {
                let payload = Data(text.utf8)
                logger.info("Relay input received (\(payload.count) bytes)")
                onInputData?(payload)
            }
        case "terminal_resize":
            if let cols = json["cols"] as? Int, let rows = json["rows"] as? Int {
                logger.info("Relay resize received (\(cols)x\(rows))")
                onResize?(cols, rows)
            }
        case "terminal_scroll":
            if let lines = json["lines"] as? Int {
                logger.info("Relay scroll received (\(lines) lines)")
                onScroll?(lines)
            }
        case "terminal_scroll_cancel":
            logger.info("Relay scroll cancel received")
            onScrollCancel?()
        case "sim_cursor_move":
            if let dx = json["dx"] as? Double, let dy = json["dy"] as? Double {
                onSimCursorMove?(dx, dy)
            }
        case "sim_click":
            if let clickCount = json["clickCount"] as? Int {
                logger.info("sim_click clicks=\(clickCount)")
                onSimClick?(clickCount)
            }
        case "sim_button":
            if let action = json["action"] as? String {
                onSimButton?(action)
            }
        case "sim_keyframe_request":
            onSimKeyframeRequest?()
        case "sim_drag_begin":
            onSimDragBegin?()
        case "sim_drag_move":
            if let dx = json["dx"] as? Double, let dy = json["dy"] as? Double {
                onSimDragMove?(dx, dy)
            }
        case "sim_drag_end":
            onSimDragEnd?()
        default:
            break
        }
    }
}

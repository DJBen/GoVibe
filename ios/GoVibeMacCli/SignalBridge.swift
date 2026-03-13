import Foundation

final class SignalBridge: @unchecked Sendable {
    private let logger: Logger
    private var wsTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private let queue = DispatchQueue(label: "dev.govibe.maccli.signalbridge")
    private var outboundQueue: [String] = []
    private var isSending = false
    private var reconnectScheduled = false
    private var socketGeneration: UInt64 = 0
    private var room: String?
    private var relayBase: String?
    private let maxQueuedMessages = 2000

    var onInputData: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var onScroll: ((Int) -> Void)?
    var onScrollCancel: (() -> Void)?
    var onPeerJoined: (() -> Void)?
    var onPeerLeft: (() -> Void)?
    var onPeerHeartbeat: (() -> Void)?
    var onSimCursorMove: ((Double, Double) -> Void)?   // dx, dy relative delta
    var onSimClick: ((Int) -> Void)?                   // clickCount only (trackpad model)
    var onSimButton: ((String) -> Void)?
    var onSimKeyframeRequest: (() -> Void)?

    init(logger: Logger) {
        self.logger = logger
    }

    func start(room: String, relayBase: String) {
        self.room = room
        self.relayBase = relayBase
        connect()
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

    func sendTerminalOutput(_ data: Data) {
        let payload: [String: String] = [
            "type": "terminal_output",
            "encoding": "base64",
            "data": data.base64EncodedString()
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        queue.async {
            if self.outboundQueue.count >= self.maxQueuedMessages {
                self.outboundQueue.removeFirst(self.outboundQueue.count - self.maxQueuedMessages + 1)
            }
            self.outboundQueue.append(json)
            self.flushOutboundQueueLocked()
        }
    }

    func sendPaneProgram(_ name: String) {
        let payload: [String: String] = [
            "type": "pane_program",
            "name": name
        ]
        enqueueJSON(payload)
    }

    func sendSnapshot(_ data: Data) {
        let payload: [String: String] = [
            "type": "terminal_snapshot",
            "encoding": "base64",
            "data": data.base64EncodedString()
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        queue.async {
            // Snapshot supersedes all buffered live output — clear the queue first.
            self.outboundQueue.removeAll()
            self.outboundQueue.insert(json, at: 0)
            self.flushOutboundQueueLocked()
        }
    }

    func sendPeerHeartbeat() {
        enqueueJSON(["type": "peer_heartbeat", "origin": "mac"])
    }

    func sendSimInfo(_ payload: SimInfoPayload) {
        let dict: [String: Any] = [
            "type": "sim_info",
            "deviceName": payload.deviceName,
            "udid": payload.udid,
            "screenWidth": payload.screenWidth,
            "screenHeight": payload.screenHeight,
            "scale": payload.scale,
            "fps": payload.fps
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            logger.error("sendSimInfo: JSON serialization failed")
            return
        }
        logger.info("sendSimInfo: enqueuing sim_info for \(payload.deviceName) (\(payload.screenWidth)x\(payload.screenHeight))")
        queue.async {
            self.outboundQueue.append(json)
            self.flushOutboundQueueLocked()
        }
    }

    /// Send a raw binary WebSocket frame (H.264 NAL units). Fire-and-forget — frames
    /// are dropped rather than queued if the socket is unavailable.
    func sendBinaryFrame(_ data: Data) {
        queue.async {
            guard let task = self.wsTask else { return }
            task.send(.data(data)) { [weak self] error in
                if let error {
                    self?.logger.error("Binary frame send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func sendPeerRetired(reason: String) {
        enqueueJSON([
            "type": "peer_retired",
            "reason": reason
        ])
    }

    func sendPeerRetiredSync(reason: String, timeout: TimeInterval = 0.5) {
        let payload: [String: String] = [
            "type": "peer_retired",
            "reason": reason
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        let group = DispatchGroup()
        queue.sync {
            guard let task = self.wsTask else { return }
            group.enter()
            task.send(.string(json)) { [weak self] error in
                if let error {
                    self?.logger.error("Relay send failed: \(error.localizedDescription)")
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
    }

    private func enqueueJSON(_ payload: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        queue.async {
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
                guard generation == self.socketGeneration else {
                    return
                }
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
        // Drop buffered stream data from a broken socket; a fresh tmux snapshot
        // on reconnect is the source of truth for state reconstruction.
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
                    guard generation == self.socketGeneration else {
                        return
                    }
                    switch result {
                    case .failure(let error):
                        self.logger.error("Relay receive failed: \(error.localizedDescription)")
                        self.scheduleReconnectLocked()
                    case .success(let message):
                        switch message {
                        case .string(let raw):
                            self.handleMessage(raw)
                        case .data(let data):
                            // iOS messages are encoded as JSON text; try UTF-8 decode and
                            // fall back to ignoring raw binary.
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

        if type == "peer_joined" {
            onPeerJoined?()
            return
        }

        if type == "peer_left" {
            onPeerLeft?()
            return
        }

        if type == "peer_heartbeat" {
            let origin = (json["origin"] as? String)?.lowercased()
            // Ignore our own heartbeat if relay echoes sender messages.
            if origin != "mac" {
                onPeerHeartbeat?()
            }
            return
        }

        if type == "terminal_input" {
            if let encoding = json["encoding"] as? String,
               encoding.lowercased() == "base64",
               let encoded = json["data"] as? String,
               let payload = Data(base64Encoded: encoded) {
                logger.info("Relay input received (\(payload.count) bytes)")
                onInputData?(payload)
                return
            }

            // Legacy compatibility path.
            if let text = json["text"] as? String {
                let payload = Data(text.utf8)
                logger.info("Relay input received (\(payload.count) bytes)")
                onInputData?(payload)
            }
            return
        }

        if type == "terminal_resize",
           let cols = json["cols"] as? Int,
           let rows = json["rows"] as? Int {
            logger.info("Relay resize received (\(cols)x\(rows))")
            onResize?(cols, rows)
            return
        }

        if type == "terminal_scroll",
           let lines = json["lines"] as? Int {
            logger.info("Relay scroll received (\(lines) lines)")
            onScroll?(lines)
            return
        }

        if type == "terminal_scroll_cancel" {
            logger.info("Relay scroll cancel received")
            onScrollCancel?()
            return
        }

        if type == "sim_cursor_move",
           let dx = json["dx"] as? Double,
           let dy = json["dy"] as? Double {
            onSimCursorMove?(dx, dy)
            return
        }

        if type == "sim_click",
           let clickCount = json["clickCount"] as? Int {
            logger.info("sim_click clicks=\(clickCount)")
            onSimClick?(clickCount)
            return
        }

        if type == "sim_button",
           let action = json["action"] as? String {
            onSimButton?(action)
            return
        }

        if type == "sim_keyframe_request" {
            onSimKeyframeRequest?()
        }
    }
}

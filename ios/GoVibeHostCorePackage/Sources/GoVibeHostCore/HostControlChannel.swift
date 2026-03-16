import Foundation

/// Listens on the host's control relay room (`<hostId>-ctl`) for commands from iOS peers.
/// Currently handles `create_session` to allow iOS to remotely create terminal sessions.
public final class HostControlChannel: @unchecked Sendable {
    private let hostId: String
    private let relayBase: String
    private let logger: HostLogger
    private let queue = DispatchQueue(label: "dev.govibe.host.control", qos: .userInitiated)
    private let urlSession = URLSession(configuration: .default)
    private var wsTask: URLSessionWebSocketTask?
    private var socketGeneration: UInt64 = 0
    private var reconnectScheduled = false
    private var stopped = false

    /// Called when an iOS peer requests session creation.
    /// Parameters: sessionId, optional tmuxSession name.
    /// Call `sendSessionCreated` or `sendSessionError` in response.
    public var onCreateSession: ((String, String?) -> Void)?

    /// Called when an iOS peer requests the list of all sessions.
    /// Respond by calling `sendSessionsList(_:)`.
    public var onListSessions: (() -> Void)?

    public init(hostId: String, relayBase: String, logger: HostLogger) {
        self.hostId = hostId
        self.relayBase = relayBase
        self.logger = logger
    }

    public func start() {
        queue.async { self.connect() }
    }

    public func stop() {
        queue.sync {
            stopped = true
            socketGeneration &+= 1
            reconnectScheduled = false
            wsTask?.cancel(with: .goingAway, reason: nil)
            wsTask = nil
        }
    }

    public func sendSessionCreated(sessionId: String) {
        sendJSON(["type": "session_created", "sessionId": sessionId])
    }

    public func sendSessionError(sessionId: String, error: String) {
        sendJSON(["type": "session_error", "sessionId": sessionId, "error": error])
    }

    /// Sends the full session list to connected iOS peers.
    /// Call this in response to `onListSessions`, and after any local session creation.
    public func sendSessionsList(_ sessions: [(sessionId: String, kind: String)]) {
        let list = sessions.map { ["sessionId": $0.sessionId, "kind": $0.kind] }
        sendRawJSON(["type": "sessions_list", "sessions": list] as [String: Any])
    }

    // MARK: - Private

    private var controlRoomId: String { "\(hostId)-ctl" }

    private func connect() {
        guard !stopped else { return }
        guard var components = URLComponents(string: relayBase) else {
            logger.error("HostControl: invalid relay URL: \(relayBase)")
            return
        }
        components.queryItems = [URLQueryItem(name: "room", value: controlRoomId)]
        guard let url = components.url else {
            logger.error("HostControl: failed to compose relay URL")
            return
        }

        logger.info("HostControl: connecting to \(url.absoluteString)")
        socketGeneration &+= 1
        let task = urlSession.webSocketTask(with: url)
        task.resume()
        wsTask = task
        receiveLoop(generation: socketGeneration)
    }

    private func scheduleReconnect() {
        guard !reconnectScheduled, !stopped else { return }
        reconnectScheduled = true
        socketGeneration &+= 1
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil

        queue.asyncAfter(deadline: .now() + 5.0) {
            self.reconnectScheduled = false
            self.connect()
        }
    }

    private func receiveLoop(generation: UInt64) {
        guard let task = wsTask else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard generation == self.socketGeneration else { return }
                switch result {
                case .failure(let error):
                    self.logger.error("HostControl receive error: \(error.localizedDescription)")
                    self.scheduleReconnect()
                case .success(let message):
                    if case .string(let text) = message {
                        self.handleMessage(text)
                    }
                    self.receiveLoop(generation: generation)
                }
            }
        }
    }

    private func handleMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "create_session":
            guard let sessionId = json["sessionId"] as? String, !sessionId.isEmpty else {
                logger.error("HostControl: create_session missing sessionId")
                return
            }
            let tmuxSession = json["tmuxSession"] as? String
            logger.info("HostControl: create_session '\(sessionId)' tmux=\(tmuxSession ?? "<same>")")
            onCreateSession?(sessionId, tmuxSession)
        case "list_sessions":
            logger.info("HostControl: list_sessions requested")
            onListSessions?()
        default:
            break
        }
    }

    private func sendJSON(_ payload: [String: String]) {
        sendRawJSON(payload)
    }

    private func sendRawJSON(_ payload: Any) {
        queue.async {
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8),
                  let task = self.wsTask else { return }
            task.send(.string(json)) { [weak self] error in
                if let error {
                    self?.logger.error("HostControl send error: \(error.localizedDescription)")
                }
            }
        }
    }
}

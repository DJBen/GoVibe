import Foundation

struct HostSessionSummary: Sendable {
    let sessionId: String
    let kind: SessionKind?
}

enum HostControlError: LocalizedError {
    case timeout
    case connectionFailed(String)
    case sessionError(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Request timed out. Is the Mac host running?"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .sessionError(let msg):
            return msg
        }
    }
}

/// Connects to a host's control relay room and sends a create_session command.
struct HostControlClient {
    let relayWebSocketBase: String
    let apiBaseURL: URL?

    init(relayWebSocketBase: String, apiBaseURL: URL? = nil) {
        self.relayWebSocketBase = relayWebSocketBase
        self.apiBaseURL = apiBaseURL
    }

    /// Connects to `<hostId>-ctl` relay room, sends create_session, and awaits confirmation.
    func createSession(
        hostId: String,
        sessionId: String,
        tmuxSession: String?
    ) async throws {
        let roomId = "\(hostId)-ctl"
        let relayAuthClient = RelayAuthClient(relayWebSocketBase: relayWebSocketBase, apiBaseURL: apiBaseURL)
        let url = try await relayAuthClient.authorizedURL(hostId: hostId, room: roomId, role: "client-control")

        let urlSession = URLSession(configuration: .default)
        let task = urlSession.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        // Build create_session message
        var payload: [String: String] = [
            "type": "create_session",
            "sessionId": sessionId,
        ]
        if let tmux = tmuxSession, !tmux.isEmpty {
            payload["tmuxSession"] = tmux
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            throw HostControlError.connectionFailed("Failed to encode message")
        }

        try await task.send(.string(json))

        // Typed response to satisfy Swift 6 Sendable requirements
        enum ControlResponse: Sendable {
            case created
            case error(String)
        }

        // Receive messages until session_created or session_error for our session ID
        let response: ControlResponse = try await withThrowingTaskGroup(of: ControlResponse.self) { group in
            group.addTask {
                while true {
                    let message = try await task.receive()
                    let text: String
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default: continue
                    }

                    guard let responseData = text.data(using: .utf8),
                          let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: String],
                          let type = parsed["type"],
                          parsed["sessionId"] == sessionId else { continue }

                    if type == "session_created" {
                        return .created
                    } else if type == "session_error" {
                        return .error(parsed["error"] ?? "Unknown error")
                    }
                }
                throw HostControlError.connectionFailed("Connection closed without response")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw HostControlError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        if case .error(let msg) = response {
            throw HostControlError.sessionError(msg)
        }
        // .created — success
    }

    /// Connects to `<hostId>-ctl` and requests deletion of a session.
    /// - Parameter killTmux: If `true`, the host kills the underlying tmux session. If `false`, GoVibe detaches without killing tmux.
    func deleteSession(hostId: String, sessionId: String, killTmux: Bool = true) async throws {
        let roomId = "\(hostId)-ctl"
        let relayAuthClient = RelayAuthClient(relayWebSocketBase: relayWebSocketBase, apiBaseURL: apiBaseURL)
        let url = try await relayAuthClient.authorizedURL(hostId: hostId, room: roomId, role: "client-control")

        let urlSession = URLSession(configuration: .default)
        let task = urlSession.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        guard let data = try? JSONSerialization.data(withJSONObject: [
            "type": "delete_session",
            "sessionId": sessionId,
            "killTmux": killTmux
        ] as [String: Any]), let json = String(data: data, encoding: .utf8) else {
            throw HostControlError.connectionFailed("Failed to encode message")
        }

        try await task.send(.string(json))

        enum ControlResponse: Sendable {
            case deleted
            case error(String)
        }

        let response: ControlResponse = try await withThrowingTaskGroup(of: ControlResponse.self) { group in
            group.addTask {
                while true {
                    let message = try await task.receive()
                    let text: String
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default: continue
                    }

                    guard let responseData = text.data(using: .utf8),
                          let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: String],
                          let type = parsed["type"],
                          parsed["sessionId"] == sessionId else { continue }

                    if type == "session_deleted" {
                        return .deleted
                    } else if type == "session_error" {
                        return .error(parsed["error"] ?? "Unknown error")
                    }
                }
                throw HostControlError.connectionFailed("Connection closed without response")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw HostControlError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        if case .error(let msg) = response {
            throw HostControlError.sessionError(msg)
        }
    }

    /// Connects to `<hostId>-ctl`, sends `list_tmux_sessions`, and returns running tmux session names.
    func listTmuxSessions(hostId: String, timeout: Duration = .seconds(8)) async throws -> [String] {
        let roomId = "\(hostId)-ctl"
        let relayAuthClient = RelayAuthClient(relayWebSocketBase: relayWebSocketBase, apiBaseURL: apiBaseURL)
        let url = try await relayAuthClient.authorizedURL(hostId: hostId, room: roomId, role: "client-control")

        let urlSession = URLSession(configuration: .default)
        let task = urlSession.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "list_tmux_sessions"]),
              let json = String(data: data, encoding: .utf8) else {
            throw HostControlError.connectionFailed("Failed to encode message")
        }
        try await task.send(.string(json))

        return try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                while true {
                    let message = try await task.receive()
                    let text: String
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default: continue
                    }
                    guard let responseData = text.data(using: .utf8),
                          let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                          parsed["type"] as? String == "tmux_sessions_list",
                          let sessions = parsed["sessions"] as? [String] else { continue }
                    return sessions
                }
                throw HostControlError.connectionFailed("Connection closed without response")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HostControlError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

}

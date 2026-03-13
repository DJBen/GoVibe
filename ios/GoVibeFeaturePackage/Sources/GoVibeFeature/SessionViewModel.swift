import Foundation
import Observation

@MainActor
@Observable
final class SessionViewModel {
    private static let peerStaleTimeout: TimeInterval = 8

    var logs: [TerminalLine] = [TerminalLine(text: "GoVibe ready")]
    var relayStatus: String = "Disconnected"

    private let relayCandidates: [String]
    private var relayTask: URLSessionWebSocketTask?
    private var terminalOutputSink: ((Data) -> Void)?
    private var terminalResetSink: (() -> Void)?
    var lastKnownTerminalSize: (cols: Int, rows: Int)?
    private(set) var relayConnectTrigger: Int = 0
    private var intentionalDisconnect = false
    private(set) var isInTmuxScrollMode = false
    var paneProgram: String?
    private var peerWatchdogTask: Task<Void, Never>?
    private var lastPeerActivityAt: Date?
    private var hasLivePeer = false

    let macDeviceId: String

    init(
        macDeviceId: String,
        relayBase: String = AppRuntimeConfig.relayWebSocketBase
    ) {
        self.relayCandidates = [relayBase]
        self.macDeviceId = macDeviceId
    }

    func connectRelayNow() {
        intentionalDisconnect = false
        relayTask?.cancel(with: .goingAway, reason: nil)
        relayTask = nil
        resetPeerState()
        relayStatus = "Connecting..."
        attemptRelayConnection(candidateIndex: 0, room: macDeviceId)
    }

    private func attemptRelayConnection(candidateIndex: Int, room: String) {
        guard candidateIndex < relayCandidates.count else {
            relayStatus = "Disconnected"
            logs.append(TerminalLine(text: "Relay connect failed across all endpoints"))
            return
        }

        let candidate = relayCandidates[candidateIndex]
        guard var components = URLComponents(string: candidate) else {
            attemptRelayConnection(candidateIndex: candidateIndex + 1, room: room)
            return
        }

        components.queryItems = [URLQueryItem(name: "room", value: room)]
        guard let url = components.url else {
            attemptRelayConnection(candidateIndex: candidateIndex + 1, room: room)
            return
        }

        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        relayTask = task
        relayConnectTrigger += 1
        relayStatus = "Waiting for Mac"
        logs.append(TerminalLine(text: "Relay connected: \(url.absoluteString)"))
        startPeerWatchdog()
        receiveLoop()
        if let size = lastKnownTerminalSize {
            sendResizeAsync(cols: size.cols, rows: size.rows)
        }
    }

    private func receiveLoop() {
        relayTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Task { @MainActor in
                    self.relayTask = nil
                    self.stopPeerWatchdog()
                    self.resetPeerState()
                    self.relayStatus = "Disconnected"
                    guard !self.intentionalDisconnect else { return }
                    self.logs.append(TerminalLine(text: "Relay error: \(error.localizedDescription). Reconnecting..."))
                    self.connectRelayNow()
                }
            case .success(let message):
                let text: String?
                switch message {
                case .string(let raw):
                    text = raw
                case .data(let data):
                    text = String(data: data, encoding: .utf8)
                @unknown default:
                    text = nil
                }

                if let text {
                    Task { @MainActor in
                        self.handleRelayMessage(text)
                    }
                }

                Task { @MainActor in
                    self.receiveLoop()
                }
            }
        }
    }

    func forceResizeSync() {
        if let size = lastKnownTerminalSize {
            sendResizeAsync(cols: size.cols, rows: size.rows)
        }
    }

    private func startPeerWatchdog() {
        stopPeerWatchdog()
        peerWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.checkPeerFreshness()
            }
        }
    }

    private func stopPeerWatchdog() {
        peerWatchdogTask?.cancel()
        peerWatchdogTask = nil
    }

    private func recordPeerActivity() {
        lastPeerActivityAt = Date()
        if !hasLivePeer {
            hasLivePeer = true
            relayStatus = "Connected"
            logs.append(TerminalLine(text: "Mac peer is live"))
        }
    }

    private func markPeerRetired(reason: String) {
        guard relayTask != nil else { return }
        guard hasLivePeer || relayStatus != "Peer disconnected" else { return }
        hasLivePeer = false
        lastPeerActivityAt = nil
        relayStatus = "Peer disconnected"
        paneProgram = nil
        terminalResetSink?()
        logs.append(TerminalLine(text: reason))
    }

    private func resetPeerState() {
        hasLivePeer = false
        lastPeerActivityAt = nil
        paneProgram = nil
    }

    private func checkPeerFreshness() {
        guard relayTask != nil, hasLivePeer, let lastPeerActivityAt else { return }
        if Date().timeIntervalSince(lastPeerActivityAt) > Self.peerStaleTimeout {
            markPeerRetired(reason: "Mac session became stale")
        }
    }

    private func handleRelayMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        if type == "peer_joined" {
            recordPeerActivity()
            if let size = lastKnownTerminalSize {
                sendResizeAsync(cols: size.cols, rows: size.rows)
            }
            return
        }

        if type == "peer_heartbeat" {
            recordPeerActivity()
            return
        }

        if type == "peer_retired" {
            let reason = (json["reason"] as? String).map { "Mac session ended (\($0))" } ?? "Mac session ended"
            markPeerRetired(reason: reason)
            return
        }

        if type == "pane_program" {
            recordPeerActivity()
            paneProgram = json["name"] as? String
            return
        }

        if type == "terminal_snapshot" {
            recordPeerActivity()
            if let encoding = json["encoding"] as? String,
               encoding.lowercased() == "base64",
               let encoded = json["data"] as? String,
               let payload = Data(base64Encoded: encoded) {
                terminalResetSink?()
                terminalOutputSink?(payload)
            }
            return
        }

        if type == "terminal_output" {
            recordPeerActivity()
            if let encoding = json["encoding"] as? String,
               encoding.lowercased() == "base64",
               let encoded = json["data"] as? String,
               let payload = Data(base64Encoded: encoded) {
                terminalOutputSink?(payload)
                return
            }

            // Legacy compatibility path.
            if let text = json["text"] as? String {
                let payload = Data(text.utf8)
                terminalOutputSink?(payload)
            }
        }
    }

    func setTerminalOutputSink(_ sink: @escaping (Data) -> Void) {
        terminalOutputSink = sink
    }

    func clearTerminalOutputSink() {
        terminalOutputSink = nil
    }

    func setTerminalResetSink(_ sink: @escaping () -> Void) {
        terminalResetSink = sink
    }

    func clearTerminalResetSink() {
        terminalResetSink = nil
    }

    func sendInputData(_ payload: Data) async {
        isInTmuxScrollMode = false
        guard relayTask != nil else {
            logs.append(TerminalLine(text: "Relay not connected. Retrying..."))
            connectRelayNow()
            return
        }

        // iOS virtual keyboards may emit backspace as BS (0x08) while most shells
        // expect DEL (0x7F) for erase in canonical mode.
        let normalizedPayload = Data(payload.map { $0 == 0x08 ? 0x7F : $0 })

        let envelope: [String: String] = [
            "type": "terminal_input",
            "encoding": "base64",
            "data": normalizedPayload.base64EncodedString()
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: envelope)
            guard let text = String(data: data, encoding: .utf8) else {
                logs.append(TerminalLine(text: "Input encoding failed"))
                return
            }
            try await relayTask?.send(.string(text))
        } catch {
            logs.append(TerminalLine(text: "Send input failed: \(error.localizedDescription)"))
        }
    }

    func sendResize(cols: Int, rows: Int) async {
        lastKnownTerminalSize = (cols: cols, rows: rows)
        guard relayTask != nil else { return }
        let envelope: [String: Any] = [
            "type": "terminal_resize",
            "cols": cols,
            "rows": rows
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: envelope)
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await relayTask?.send(.string(text))
        } catch {
            logs.append(TerminalLine(text: "Resize send failed: \(error.localizedDescription)"))
        }
    }

    func sendScrollCancel() async {
        guard relayTask != nil, isInTmuxScrollMode else { return }
        isInTmuxScrollMode = false
        let envelope: [String: Any] = ["type": "terminal_scroll_cancel"]
        do {
            let data = try JSONSerialization.data(withJSONObject: envelope)
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await relayTask?.send(.string(text))
        } catch {
            logs.append(TerminalLine(text: "Scroll cancel failed: \(error.localizedDescription)"))
        }
    }

    func sendScrollCancelAsync() {
        Task { @MainActor in await sendScrollCancel() }
    }

    func sendScroll(lines: Int) async {
        guard relayTask != nil else { return }
        guard lines != 0 else { return }
        if lines > 0 { isInTmuxScrollMode = true }
        let envelope: [String: Any] = [
            "type": "terminal_scroll",
            "lines": lines
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: envelope)
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await relayTask?.send(.string(text))
        } catch {
            logs.append(TerminalLine(text: "Scroll send failed: \(error.localizedDescription)"))
        }
    }

    func sendInputDataAsync(_ payload: Data) {
        Task { @MainActor in
            await sendInputData(payload)
        }
    }

    func sendResizeAsync(cols: Int, rows: Int) {
        Task { @MainActor in
            await sendResize(cols: cols, rows: rows)
        }
    }

    func sendScrollAsync(lines: Int) {
        Task { @MainActor in
            await sendScroll(lines: lines)
        }
    }

    func sendInput(_ input: String) async {
        let line = input.hasSuffix("\n") ? input : input + "\n"
        await sendInputData(Data(line.utf8))
        logs.append(TerminalLine(text: "> \(input)"))
    }

    func disconnectRelay() {
        intentionalDisconnect = true
        stopPeerWatchdog()
        relayTask?.cancel(with: .goingAway, reason: nil)
        relayTask = nil
        resetPeerState()
        relayStatus = "Disconnected"
    }

    func debugDisconnectAndReconnectRelay() {
        logs.append(TerminalLine(text: "#DEBUG: forcing relay reconnect"))
        disconnectRelay()
        connectRelayNow()
    }
}

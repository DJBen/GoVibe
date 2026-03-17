import FirebaseAuth
import Foundation
import Observation
#if canImport(UIKit)
import AVFoundation
import UIKit
#endif

@MainActor
@Observable
final class SessionViewModel {
    private static let peerStaleTimeout: TimeInterval = 8

    var logs: [TerminalLine] = [TerminalLine(text: "GoVibe ready")]
    var sessionId: String = ""
    var isBusy = false
    var relayStatus: String = "Disconnected"

    private let apiClient: GoVibeAPIClient
    private let relayCandidates: [String]
    private var relayTask: URLSessionWebSocketTask?
    private var terminalOutputSink: ((Data) -> Void)?
    private var terminalResetSink: (() -> Void)?
    var lastKnownTerminalSize: (cols: Int, rows: Int)?
    private(set) var relayConnectTrigger: Int = 0
    private var intentionalDisconnect = false
    private(set) var isInTmuxScrollMode = false
    var paneProgram: String?
    private(set) var planState: TerminalPlanState?
    private var peerWatchdogTask: Task<Void, Never>?
    private var outboundHeartbeatTask: Task<Void, Never>?
    private var lastPeerActivityAt: Date?
    private var hasLivePeer = false

    // Simulator mirror
    private(set) var simInfo: SimInfo?
    #if canImport(UIKit)
    var videoDecoder: SimulatorVideoDecoder?
    var captureSnapshot: (() -> UIImage?)?   // registered by the active surface view
    var pendingSnapshotImage: UIImage?       // captured eagerly during dismantleUIView
    #endif

    let iosDeviceId: String
    let macDeviceId: String

    init(
        macDeviceId: String,
        apiBaseURL: URL = AppRuntimeConfig.apiBaseURL,
        relayBase: String = AppRuntimeConfig.relayWebSocketBase
    ) {
        self.apiClient = GoVibeAPIClient(baseURL: apiBaseURL)
        self.relayCandidates = [relayBase]

        #if canImport(UIKit)
        self.iosDeviceId = UIDevice.current.identifierForVendor?.uuidString ?? "ios-demo-01"
        #else
        self.iosDeviceId = "ios-demo-01"
        #endif
        self.macDeviceId = macDeviceId
    }

    func bootstrapAuth() async {
        if Auth.auth().currentUser == nil {
            do {
                _ = try await Auth.auth().signInAnonymously()
                logs.append(TerminalLine(text: "Signed in anonymously"))
            } catch {
                logs.append(TerminalLine(text: "Auth failed: \(error.localizedDescription)"))
            }
        }

        // Register whatever FCM token is already available, then stay subscribed to refreshes.
        GoVibeAppDelegate.onFCMTokenRefresh = { [weak self] token in
            Task { @MainActor [weak self] in
                try? await self?.apiClient.registerFCMToken(token, deviceId: self?.iosDeviceId ?? "")
            }
        }
        if let token = GoVibeAppDelegate.latestFCMToken {
            try? await apiClient.registerFCMToken(token, deviceId: iosDeviceId)
        }

        connectRelayNow()
    }

    func createSession() async {
        isBusy = true
        defer { isBusy = false }

        do {
            let response = try await apiClient.sessionCreate(ownerDeviceId: iosDeviceId, peerDeviceId: macDeviceId)
            sessionId = response.sessionId
            logs.append(TerminalLine(text: "Session created: \(response.sessionId)"))
        } catch {
            logs.append(TerminalLine(text: "Session create failed: \(error.localizedDescription)"))
        }

        connectRelayNow()
    }

    func connectRelayNow() {
        intentionalDisconnect = false
        stopOutboundHeartbeat()
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

        components.queryItems = [
            URLQueryItem(name: "room", value: room),
            URLQueryItem(name: "iosDeviceId", value: iosDeviceId)
        ]
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
        startOutboundHeartbeat()
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
                    self.stopOutboundHeartbeat()
                    self.resetPeerState()
                    self.relayStatus = "Disconnected"
                    guard !self.intentionalDisconnect else { return }
                    self.logs.append(TerminalLine(text: "Relay error: \(error.localizedDescription). Reconnecting..."))
                    self.connectRelayNow()
                }
            case .success(let message):
                switch message {
                case .string(let raw):
                    Task { @MainActor in
                        self.handleRelayMessage(raw)
                    }
                case .data(let data):
                    Task { @MainActor in
                        // The relay forwards all messages as binary WebSocket frames.
                        // JSON control messages (sim_info, peer_heartbeat, etc.) start with '{'.
                        // Actual binary H.264 frames use our custom 5-byte header (first byte 0x01 or 0x02).
                        if data.first != 0x01 && data.first != 0x02,
                           let text = String(data: data, encoding: .utf8) {
                            self.handleRelayMessage(text)
                        } else {
                            self.handleBinaryRelayFrame(data)
                        }
                    }
                @unknown default:
                    break
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
                self?.checkPeerFreshness()
            }
        }
    }

    private func stopPeerWatchdog() {
        peerWatchdogTask?.cancel()
        peerWatchdogTask = nil
    }

    private func startOutboundHeartbeat() {
        stopOutboundHeartbeat()
        outboundHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await self?.sendClientHeartbeat()
            }
        }
    }

    private func stopOutboundHeartbeat() {
        outboundHeartbeatTask?.cancel()
        outboundHeartbeatTask = nil
    }

    private func sendClientHeartbeat() async {
        guard relayTask != nil else { return }
        await sendJSONEnvelope(["type": "peer_heartbeat", "origin": "ios"])
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
        planState = nil
        simInfo = nil
        #if canImport(UIKit)
        videoDecoder?.reset()
        videoDecoder = nil
        #endif
        terminalResetSink?()
        logs.append(TerminalLine(text: reason))
    }

    private func resetPeerState() {
        hasLivePeer = false
        lastPeerActivityAt = nil
        paneProgram = nil
        planState = nil
        simInfo = nil
        #if canImport(UIKit)
        videoDecoder = nil
        #endif
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

        if type == "sim_info" {
            recordPeerActivity()
            if let deviceName = json["deviceName"] as? String,
               let udid = json["udid"] as? String,
               let screenWidth = (json["screenWidth"] as? NSNumber)?.intValue,
               let screenHeight = (json["screenHeight"] as? NSNumber)?.intValue,
               let scale = (json["scale"] as? NSNumber)?.doubleValue,
               let fps = (json["fps"] as? NSNumber)?.intValue {
                let info = SimInfo(deviceName: deviceName, udid: udid,
                                   screenWidth: screenWidth, screenHeight: screenHeight,
                                   scale: scale, fps: fps)
                simInfo = info
                #if canImport(UIKit)
                if videoDecoder == nil {
                    videoDecoder = SimulatorVideoDecoder { [weak self] in
                        self?.sendSimKeyframeRequestAsync()
                    }
                }
                #endif
            }
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
            let origin = (json["origin"] as? String)?.lowercased()
            if origin != "ios" {
                recordPeerActivity()
            }
            return
        }

        if type == "peer_retired" {
            let reason = (json["reason"] as? String).map { "Mac session ended (\($0))" } ?? "Mac session ended"
            markPeerRetired(reason: reason)
            return
        }

        if type == "push_notify" {
            recordPeerActivity()
            return
        }

        if type == "plan_state" {
            recordPeerActivity()
            let available = (json["available"] as? Bool) ?? false
            if available,
               let assistant = json["assistant"] as? String,
               let turnId = json["turnId"] as? String,
               let markdown = json["markdown"] as? String,
               let blockCount = json["blockCount"] as? Int {
                planState = TerminalPlanState(
                    assistant: assistant,
                    turnId: turnId,
                    title: json["title"] as? String,
                    markdown: markdown,
                    blockCount: blockCount
                )
            } else {
                planState = nil
            }
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

    // MARK: - Simulator Mirror

    func handleBinaryRelayFrame(_ data: Data) {
        recordPeerActivity()
        #if canImport(UIKit)
        videoDecoder?.receiveBinaryFrame(data)
        #endif
    }

    #if canImport(UIKit)
    func connectDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        print("[SessionViewModel] connectDisplayLayer called, decoder=\(videoDecoder != nil ? "ready" : "nil")")
        videoDecoder?.setDisplayLayer(layer)
    }
    #endif

    func sendSimCursorMove(dx: Double, dy: Double) async {
        guard relayTask != nil else { return }
        await sendJSONEnvelope(["type": "sim_cursor_move", "dx": dx, "dy": dy])
    }

    func sendSimClick(button: String = "left", clickCount: Int) async {
        guard relayTask != nil else { return }
        await sendJSONEnvelope(["type": "sim_click", "button": button, "clickCount": clickCount])
    }

    func sendSimButton(action: String) async {
        guard relayTask != nil else { return }
        await sendJSONEnvelope(["type": "sim_button", "action": action])
    }

    func sendSimScroll(dx: Double, dy: Double) async {
        guard relayTask != nil else { return }
        await sendJSONEnvelope(["type": "sim_scroll", "dx": dx, "dy": dy])
    }

    private func sendSimKeyframeRequest() async {
        guard relayTask != nil else { return }
        await sendJSONEnvelope(["type": "sim_keyframe_request"])
    }

    private func sendJSONEnvelope(_ envelope: [String: Any]) async {
        do {
            let data = try JSONSerialization.data(withJSONObject: envelope)
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await relayTask?.send(.string(text))
        } catch {
            logs.append(TerminalLine(text: "Send failed: \(error.localizedDescription)"))
        }
    }

    func sendSimCursorMoveAsync(dx: Double, dy: Double) {
        Task { @MainActor in await sendSimCursorMove(dx: dx, dy: dy) }
    }

    func sendSimClickAsync(button: String = "left", clickCount: Int) {
        Task { @MainActor in await sendSimClick(button: button, clickCount: clickCount) }
    }

    func sendSimButtonAsync(action: String) {
        Task { @MainActor in await sendSimButton(action: action) }
    }

    func sendSimScrollAsync(dx: Double, dy: Double) {
        Task { @MainActor in await sendSimScroll(dx: dx, dy: dy) }
    }

    func sendSimKeyframeRequestAsync() {
        Task { @MainActor in await sendSimKeyframeRequest() }
    }

    func sendSimDragBeginAsync() {
        Task { await sendJSONEnvelope(["type": "sim_drag_begin"]) }
    }

    func sendSimDragMoveAsync(dx: Double, dy: Double) {
        Task { await sendJSONEnvelope(["type": "sim_drag_move", "dx": dx, "dy": dy]) }
    }

    func sendSimDragEndAsync() {
        Task { await sendJSONEnvelope(["type": "sim_drag_end"]) }
    }

    func disconnectRelay() {
        intentionalDisconnect = true
        stopPeerWatchdog()
        stopOutboundHeartbeat()
        relayTask?.cancel(with: .goingAway, reason: nil)
        relayTask = nil
        #if canImport(UIKit)
        videoDecoder?.reset()
        #endif
        resetPeerState()
        relayStatus = "Disconnected"
    }

    func debugDisconnectAndReconnectRelay() {
        logs.append(TerminalLine(text: "#DEBUG: forcing relay reconnect"))
        disconnectRelay()
        connectRelayNow()
    }
}

import Foundation

enum CodexPushEvent: String {
    case awaitingApproval = "codex_approval_required"
    case turnComplete = "codex_turn_complete"
}

/// Watches Codex session JSONL files and fires push events based on explicit
/// conversation records:
/// - `task_complete` => turn complete
/// - pending escalated `function_call` (no matching `function_call_output`) => awaiting approval
///
/// Polling is driven externally — call `poll()` every second from the host session.
final class CodexLogWatcher {
    private let sessionsRoot: URL
    private let logger: HostLogger
    private var cwd: String
    private var fileURL: URL?
    private var readOffset: UInt64 = 0
    private var lastNotifiedTurnID: String?
    private var pendingEscalatedCallIDs: Set<String> = []
    private var approvalNotificationPending = false
    private var fileCwdCache: [String: String?] = [:]
    private var lastScanAt: Date?
    private static let rescanInterval: TimeInterval = 3
    private var currentPlanArtifact: TerminalPlanArtifact?
    private var pendingAssistantOutputs: [String] = []

    let onTurnComplete: (CodexPushEvent) -> Void
    let onPlanStateChanged: (TerminalPlanArtifact?) -> Void

    init(
        cwd: String,
        logger: HostLogger,
        onTurnComplete: @escaping (CodexPushEvent) -> Void,
        onPlanStateChanged: @escaping (TerminalPlanArtifact?) -> Void
    ) {
        self.cwd = cwd
        self.logger = logger
        self.sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        self.onTurnComplete = onTurnComplete
        self.onPlanStateChanged = onPlanStateChanged
    }

    /// Update the working directory (e.g. when the tmux pane's cwd changes).
    func updateCwd(_ newCwd: String) {
        guard newCwd != cwd else { return }
        logger.info("CodexLogWatcher: cwd updated \(cwd) -> \(newCwd)")
        cwd = newCwd
        reset()
    }

    /// Called every second by `TerminalHostSession.pollPaneProgram()` while Codex is active.
    func poll() {
        refreshFileIfNeeded()
        guard let url = fileURL else { return }
        let newLines = readNewLines(from: url)
        guard !newLines.isEmpty else { return }

        for line in newLines {
            guard
                let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = obj["type"] as? String,
                let payload = obj["payload"] as? [String: Any]
            else { continue }

            if type == "event_msg" {
                handleEventMessage(payload: payload)
            } else if type == "response_item" {
                handleResponseItem(payload: payload)
            }
        }

        if !approvalNotificationPending, !pendingEscalatedCallIDs.isEmpty {
            approvalNotificationPending = true
            logger.info("CodexLogWatcher: pending escalated tool call detected, firing approval push")
            onTurnComplete(.awaitingApproval)
        }
    }

    /// Called when the pane switches away from Codex.
    func reset() {
        logger.info("CodexLogWatcher: reset (pane switched away from Codex)")
        fileURL = nil
        readOffset = 0
        lastNotifiedTurnID = nil
        pendingEscalatedCallIDs.removeAll()
        approvalNotificationPending = false
        lastScanAt = nil
        pendingAssistantOutputs.removeAll()
        updatePlanArtifact(nil)
    }

    // MARK: - Private

    private func handleEventMessage(payload: [String: Any]) {
        guard let eventType = payload["type"] as? String else { return }

        if eventType == "task_complete" {
            let turnID = payload["turn_id"] as? String
            if let turnID, turnID != lastNotifiedTurnID {
                logger.info("CodexLogWatcher: task_complete detected, firing turn complete push")
                lastNotifiedTurnID = turnID
                let text = pendingAssistantOutputs.joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let artifact = TerminalPlanParser.parseArtifact(
                    assistant: "Codex",
                    turnId: turnID,
                    text: text
                ) {
                    updatePlanArtifact(artifact)
                }
                pendingAssistantOutputs.removeAll()
                pendingEscalatedCallIDs.removeAll()
                approvalNotificationPending = false
                onTurnComplete(.turnComplete)
            }
            return
        }

        if eventType == "turn_aborted" || eventType == "task_started" || eventType == "user_message" {
            pendingEscalatedCallIDs.removeAll()
            approvalNotificationPending = false
            pendingAssistantOutputs.removeAll()
            updatePlanArtifact(nil)
        }
    }

    private func handleResponseItem(payload: [String: Any]) {
        guard let itemType = payload["type"] as? String else { return }

        if itemType == "message",
           payload["role"] as? String == "assistant",
           let content = payload["content"] as? [[String: Any]] {
            let textParts = content.compactMap { item -> String? in
                guard item["type"] as? String == "output_text" else { return nil }
                return item["text"] as? String
            }
            if !textParts.isEmpty {
                pendingAssistantOutputs.append(textParts.joined(separator: "\n\n"))
            }
            return
        }

        if itemType == "function_call" {
            guard let callID = payload["call_id"] as? String else { return }
            guard let argsText = payload["arguments"] as? String else { return }
            guard
                let argsData = argsText.data(using: .utf8),
                let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
            else { return }
            let sandboxPermissions = args["sandbox_permissions"] as? String
            if sandboxPermissions == "require_escalated" {
                pendingEscalatedCallIDs.insert(callID)
            }
            return
        }

        if itemType == "function_call_output", let callID = payload["call_id"] as? String {
            pendingEscalatedCallIDs.remove(callID)
            if pendingEscalatedCallIDs.isEmpty {
                approvalNotificationPending = false
            }
        }
    }

    private func refreshFileIfNeeded() {
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
            if fileURL != nil {
                logger.info("CodexLogWatcher: sessions root not found at \(sessionsRoot.path)")
                reset()
            }
            return
        }

        if let current = fileURL,
           FileManager.default.fileExists(atPath: current.path),
           sessionFileCwd(for: current) == cwd,
           let lastScanAt,
           Date().timeIntervalSince(lastScanAt) < Self.rescanInterval {
            return
        }

        lastScanAt = Date()

        guard let newest = newestSessionFileForCurrentCwd() else {
            if fileURL != nil {
                logger.info("CodexLogWatcher: no matching rollout .jsonl for cwd=\(cwd)")
                reset()
            }
            return
        }

        if newest != fileURL {
            // Seek to end so we don't replay historical turns written before this watcher became active.
            let endOffset = (try? FileManager.default.attributesOfItem(atPath: newest.path)[.size] as? UInt64) ?? 0
            logger.info("CodexLogWatcher: watching \(newest.lastPathComponent) at offset \(endOffset)")
            fileURL = newest
            readOffset = endOffset
            pendingEscalatedCallIDs.removeAll()
            approvalNotificationPending = false
        }
    }

    private func newestSessionFileForCurrentCwd() -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var bestURL: URL?
        var bestDate: Date = .distantPast

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else { continue }
            guard sessionFileCwd(for: url) == cwd else { continue }

            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date > bestDate {
                bestDate = date
                bestURL = url
            }
        }

        return bestURL
    }

    private func sessionFileCwd(for fileURL: URL) -> String? {
        let key = fileURL.path
        if let cached = fileCwdCache[key] {
            return cached
        }

        guard let fh = try? FileHandle(forReadingFrom: fileURL) else {
            fileCwdCache[key] = nil
            return nil
        }
        defer { try? fh.close() }

        let data = fh.readData(ofLength: 16 * 1024)
        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\n", maxSplits: 1).first,
              let lineData = String(firstLine).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = obj["type"] as? String,
              type == "session_meta",
              let payload = obj["payload"] as? [String: Any]
        else {
            fileCwdCache[key] = nil
            return nil
        }

        let sessionCwd = payload["cwd"] as? String
        fileCwdCache[key] = sessionCwd
        return sessionCwd
    }

    private func readNewLines(from url: URL) -> [String] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        fh.seek(toFileOffset: readOffset)
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return [] }
        readOffset += UInt64(data.count)
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func updatePlanArtifact(_ artifact: TerminalPlanArtifact?) {
        guard artifact != currentPlanArtifact else { return }
        currentPlanArtifact = artifact
        onPlanStateChanged(artifact)
    }
}

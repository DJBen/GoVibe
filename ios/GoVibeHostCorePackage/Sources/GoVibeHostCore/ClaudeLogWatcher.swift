import Foundation

enum ClaudePushEvent: String {
    case awaitingApproval = "claude_approval_required"
    case turnComplete = "claude_turn_complete"
}

/// Watches Claude's JSONL conversation log and fires `onTurnComplete` whenever
/// Claude is waiting for user input — either after `end_turn` or when a
/// permission sentinel file is present (written by the `permission_prompt`
/// Notification hook in ~/.claude/settings.json).
///
/// Polling is driven externally — call `poll()` every second from the host session.
final class ClaudeLogWatcher {
    private let projectsRoot: URL
    private let logger: HostLogger
    private var cwd: String
    private var fileURL: URL?
    private var readOffset: UInt64 = 0
    private var lastNotifiedUUID: String?
    private var awaitingNextTurn = false
    private var currentPlanArtifact: TerminalPlanArtifact?

    /// Path to the sentinel file written by the Claude Code `permission_prompt`
    /// Notification hook. Presence means a real permission prompt is on-screen.
    /// The watcher consumes (deletes) it the moment it fires the push.
    static let permissionSentinelURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/govibe-permission-pending")

    let onTurnComplete: (ClaudePushEvent) -> Void
    let onPlanStateChanged: (TerminalPlanArtifact?) -> Void

    init(
        cwd: String,
        logger: HostLogger,
        onTurnComplete: @escaping (ClaudePushEvent) -> Void,
        onPlanStateChanged: @escaping (TerminalPlanArtifact?) -> Void
    ) {
        self.cwd = cwd
        self.logger = logger
        self.projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        self.onTurnComplete = onTurnComplete
        self.onPlanStateChanged = onPlanStateChanged
    }

    /// Update the working directory (e.g. when the tmux pane's cwd changes).
    func updateCwd(_ newCwd: String) {
        guard newCwd != cwd else { return }
        logger.info("ClaudeLogWatcher: cwd updated \(cwd) → \(newCwd)")
        cwd = newCwd
        fileURL = nil
        readOffset = 0
    }

    /// Called every second by `TerminalHostSession.pollPaneProgram()` while Claude is active.
    func poll() {
        refreshFileIfNeeded()
        guard let url = fileURL else { return }

        // Check for the permission sentinel before reading new lines.
        // The sentinel is written by the `permission_prompt` Notification hook in
        // ~/.claude/settings.json — it only fires when a real permission prompt is
        // on-screen, never for auto-approved tools, eliminating false positives from
        // long-running Bash commands (gh run watch, xcodebuild, brew, etc.).
        let sentinelPath = Self.permissionSentinelURL.path
        if !awaitingNextTurn,
           FileManager.default.fileExists(atPath: sentinelPath) {
            logger.info("ClaudeLogWatcher: permission sentinel detected, firing approval push")
            try? FileManager.default.removeItem(atPath: sentinelPath)
            awaitingNextTurn = true
            onTurnComplete(.awaitingApproval)
        }

        let newLines = readNewLines(from: url)
        guard !newLines.isEmpty else { return }

        for line in newLines {
            guard
                let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String
            let uuid = obj["uuid"] as? String
            let message = obj["message"] as? [String: Any]
            let stopReason = message?["stop_reason"] as? String

            if type == "user", isExternalUserPrompt(message) {
                // User replied — ready for next notification.
                if awaitingNextTurn {
                    logger.info("ClaudeLogWatcher: user turn detected, ready for next end_turn")
                }
                awaitingNextTurn = false
                updatePlanArtifact(nil)
            }

            if type == "assistant", let stopReason {
                logger.info("ClaudeLogWatcher: assistant stop_reason=\(stopReason) uuid=\(uuid ?? "nil") awaitingNextTurn=\(awaitingNextTurn)")
            }

            if type == "assistant",
               let uuid,
               let artifact = exitPlanModeArtifact(from: message, uuid: uuid) {
                logger.info("ClaudeLogWatcher: ExitPlanMode detected, publishing plan artifact")
                updatePlanArtifact(artifact)
            }

            if type == "assistant",
               stopReason == "end_turn",
               let uuid,
               uuid != lastNotifiedUUID,
               !awaitingNextTurn {
                logger.info("ClaudeLogWatcher: end_turn detected, firing push notification")
                lastNotifiedUUID = uuid
                if let text = assistantText(from: message),
                   let artifact = TerminalPlanParser.parseArtifact(assistant: "Claude", turnId: uuid, text: text) {
                    updatePlanArtifact(artifact)
                }
                awaitingNextTurn = true
                onTurnComplete(.turnComplete)
            }
        }
    }

    /// Called when the pane switches away from Claude.
    func reset() {
        logger.info("ClaudeLogWatcher: reset (pane switched away from Claude)")
        fileURL = nil
        readOffset = 0
        lastNotifiedUUID = nil
        awaitingNextTurn = false
        try? FileManager.default.removeItem(at: Self.permissionSentinelURL)
        updatePlanArtifact(nil)
    }

    // MARK: - Private

    private func projectDir() -> URL? {
        // Claude derives the project dir name by replacing every '/' in the cwd with '-'
        // (including the leading slash), e.g.:
        //   "/Users/sihaolu/Developments/GoVibe" → "-Users-sihaolu-Developments-GoVibe"
        let dirName = cwd.replacingOccurrences(of: "/", with: "-")
        let dir = projectsRoot.appendingPathComponent(dirName)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return dir
    }

    private func refreshFileIfNeeded() {
        guard let dir = projectDir() else {
            if fileURL != nil {
                logger.info("ClaudeLogWatcher: project dir not found for cwd=\(cwd)")
                fileURL = nil
            }
            return
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let jsonlFiles = contents.filter { $0.pathExtension == "jsonl" }
        let newest = jsonlFiles.max { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate < bDate
        }

        guard let newest else {
            if fileURL != nil {
                logger.info("ClaudeLogWatcher: no .jsonl files found in \(dir.path)")
                fileURL = nil
            }
            return
        }

        if newest != fileURL {
            // Seek to end so we don't replay historical turns written before this session started.
            let endOffset = (try? FileManager.default.attributesOfItem(atPath: newest.path)[.size] as? UInt64) ?? 0
            logger.info("ClaudeLogWatcher: watching \(newest.lastPathComponent) at offset \(endOffset)")
            fileURL = newest
            readOffset = endOffset
            updatePlanArtifact(existingPlanArtifact(in: newest))
        }
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

    private func assistantText(from message: [String: Any]?) -> String? {
        guard let content = message?["content"] as? [[String: Any]] else { return nil }
        let textParts = content.compactMap { item -> String? in
            guard item["type"] as? String == "text" else { return nil }
            return item["text"] as? String
        }
        let joined = textParts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private func isExternalUserPrompt(_ message: [String: Any]?) -> Bool {
        if let content = message?["content"] as? String {
            return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard let content = message?["content"] as? [[String: Any]] else { return false }
        for item in content {
            if let type = item["type"] as? String, type == "text",
               let text = item["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    private func exitPlanModeArtifact(from message: [String: Any]?, uuid: String) -> TerminalPlanArtifact? {
        guard let content = message?["content"] as? [[String: Any]] else { return nil }
        for item in content {
            guard item["type"] as? String == "tool_use",
                  item["name"] as? String == "ExitPlanMode",
                  let input = item["input"] as? [String: Any] else {
                continue
            }

            if let plan = input["plan"] as? String,
               !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return TerminalPlanArtifact(
                    assistant: "Claude",
                    turnId: uuid,
                    title: TerminalPlanParser.derivePlanTitle(from: plan),
                    markdown: plan,
                    blockCount: 1
                )
            }

            if let planFilePath = input["planFilePath"] as? String,
               let plan = try? String(contentsOfFile: planFilePath, encoding: .utf8) {
                let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return TerminalPlanArtifact(
                    assistant: "Claude",
                    turnId: uuid,
                    title: TerminalPlanParser.derivePlanTitle(from: trimmed),
                    markdown: trimmed,
                    blockCount: 1
                )
            }
        }
        return nil
    }

    private func existingPlanArtifact(in url: URL) -> TerminalPlanArtifact? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var artifact: TerminalPlanArtifact?
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String
            let uuid = obj["uuid"] as? String
            let message = obj["message"] as? [String: Any]
            let stopReason = message?["stop_reason"] as? String

            if type == "user", isExternalUserPrompt(message) {
                artifact = nil
                continue
            }

            if type == "assistant",
               let uuid,
               let planArtifact = exitPlanModeArtifact(from: message, uuid: uuid) {
                artifact = planArtifact
                continue
            }

            if type == "assistant",
               stopReason == "end_turn",
               let uuid,
               let assistantText = assistantText(from: message),
               let planArtifact = TerminalPlanParser.parseArtifact(
                assistant: "Claude",
                turnId: uuid,
                text: assistantText
               ) {
                artifact = planArtifact
            }
        }

        return artifact
    }

    private func updatePlanArtifact(_ artifact: TerminalPlanArtifact?) {
        guard artifact != currentPlanArtifact else { return }
        currentPlanArtifact = artifact
        onPlanStateChanged(artifact)
    }
}

import Foundation

enum ClaudePushEvent: String {
    case awaitingApproval = "claude_approval_required"
    case turnComplete = "claude_turn_complete"
}

/// Watches Claude's sentinel files and JSONL conversation log.
///
/// Push notifications are entirely hook-driven:
/// - Turn-complete: the `Stop` hook in ~/.claude/settings.json writes
///   `govibe-turn-complete-pending` when Claude finishes responding.
/// - Approval-required: the `Notification`/`permission_prompt` hook writes
///   `govibe-permission-pending` when a permission prompt appears.
///
/// The JSONL file is still read (at new-content-only offsets) to:
/// - Clear `awaitingNextTurn` when the user sends a new prompt, re-arming notifications.
/// - Extract plan artifacts from `ExitPlanMode` tool calls and `TerminalPlanParser`.
///
/// Polling is driven externally — call `poll()` every second from the host session.
final class ClaudeLogWatcher {
    private let projectsRoot: URL
    private let logger: HostLogger
    private var cwd: String
    private var fileURL: URL?
    private var readOffset: UInt64 = 0
    private var awaitingNextTurn = false
    private var currentPlanArtifact: TerminalPlanArtifact?
    private var lastUserPrompt: String?
    /// When set, prefer this specific session's JSONL file over the newest.
    private var targetSessionId: String?
    /// When true, the watcher has pinned to a file and should not re-evaluate.
    private var filePinned = false

    /// Session-scoped sentinel written by the `Stop` hook in ~/.claude/settings.json.
    private let turnCompleteSentinelURL: URL
    /// Session-scoped sentinel written by the `Notification`/`permission_prompt` hook.
    private let permissionSentinelURL: URL

    /// Claim file used to coordinate with other watchers sharing the same project
    /// directory. Each watcher writes the path of its claimed JSONL file here so
    /// other watchers can skip it.
    private let claimFileURL: URL

    /// Legacy global sentinel paths (no session prefix) cleaned up during reset as a migration step.
    private static let legacyTurnCompleteSentinelURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/govibe-turn-complete-pending")
    private static let legacyPermissionSentinelURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/govibe-permission-pending")

    let onTurnComplete: (ClaudePushEvent) -> Void
    let onPlanStateChanged: (TerminalPlanArtifact?) -> Void
    let onPlanArtifactsLoaded: ([TerminalPlanArtifact]) -> Void
    let onLastUserPromptChanged: (String) -> Void

    init(
        tmuxSessionName: String,
        cwd: String,
        logger: HostLogger,
        onTurnComplete: @escaping (ClaudePushEvent) -> Void,
        onPlanStateChanged: @escaping (TerminalPlanArtifact?) -> Void,
        onPlanArtifactsLoaded: @escaping ([TerminalPlanArtifact]) -> Void = { _ in },
        onLastUserPromptChanged: @escaping (String) -> Void
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let prefix = "govibe-\(tmuxSessionName)-"
        self.permissionSentinelURL = home.appendingPathComponent(".claude/\(prefix)permission-pending")
        self.turnCompleteSentinelURL = home.appendingPathComponent(".claude/\(prefix)turn-complete-pending")
        self.claimFileURL = home.appendingPathComponent(".claude/\(prefix)jsonl-claim")
        self.cwd = cwd
        self.logger = logger
        self.projectsRoot = home.appendingPathComponent(".claude/projects")
        self.onTurnComplete = onTurnComplete
        self.onPlanStateChanged = onPlanStateChanged
        self.onPlanArtifactsLoaded = onPlanArtifactsLoaded
        self.onLastUserPromptChanged = onLastUserPromptChanged
    }

    /// Update the working directory (e.g. when the tmux pane's cwd changes).
    func updateCwd(_ newCwd: String) {
        guard newCwd != cwd else { return }
        logger.info("ClaudeLogWatcher: cwd updated \(cwd) → \(newCwd)")
        cwd = newCwd
        fileURL = nil
        readOffset = 0
    }

    /// Pin to a specific Claude session's JSONL file (by sessionId UUID).
    /// When set, `refreshFileIfNeeded()` uses `{sessionId}.jsonl` directly
    /// instead of picking the newest file — required when multiple Claude
    /// sessions share the same cwd.
    func updateTargetSessionId(_ sessionId: String?) {
        guard sessionId != targetSessionId else { return }
        logger.info("ClaudeLogWatcher: targetSessionId updated → \(sessionId ?? "nil")")
        targetSessionId = sessionId
        fileURL = nil
        readOffset = 0
        filePinned = false
    }

    /// Called every second by `TerminalHostSession.pollPaneProgram()` while Claude is active.
    func poll() {
        // Check sentinels before reading JSONL — hooks are the authoritative notification source.
        let permPath = permissionSentinelURL.path
        if !awaitingNextTurn, FileManager.default.fileExists(atPath: permPath) {
            logger.info("ClaudeLogWatcher: permission sentinel detected, firing approval push")
            try? FileManager.default.removeItem(atPath: permPath)
            awaitingNextTurn = true
            onTurnComplete(.awaitingApproval)
        }

        let turnPath = turnCompleteSentinelURL.path
        if !awaitingNextTurn, FileManager.default.fileExists(atPath: turnPath) {
            logger.info("ClaudeLogWatcher: turn-complete sentinel detected, firing turn-complete push")
            try? FileManager.default.removeItem(atPath: turnPath)
            awaitingNextTurn = true
            onTurnComplete(.turnComplete)
        }

        // Read new JSONL lines for plan artifact extraction and awaitingNextTurn reset.
        refreshFileIfNeeded()
        guard let url = fileURL else { return }
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

            if type == "user", isExternalUserPrompt(message) {
                // User replied — re-arm notifications for the next turn.
                // Remove any stale sentinel files from the previous turn so they
                // don't fire immediately before the new turn's work finishes.
                if awaitingNextTurn {
                    logger.info("ClaudeLogWatcher: user turn detected, ready for next notification")
                }
                try? FileManager.default.removeItem(at: turnCompleteSentinelURL)
                try? FileManager.default.removeItem(at: permissionSentinelURL)
                awaitingNextTurn = false
                updatePlanArtifact(nil)
                updateLastUserPrompt(userPromptText(from: message))
            }

            if type == "assistant", let uuid {
                if let artifact = exitPlanModeArtifact(from: message, uuid: uuid) {
                    logger.info("ClaudeLogWatcher: ExitPlanMode detected, publishing plan artifact")
                    updatePlanArtifact(artifact)
                } else if let text = assistantText(from: message),
                          let artifact = TerminalPlanParser.parseArtifact(
                            assistant: "Claude", turnId: uuid, text: text) {
                    updatePlanArtifact(artifact)
                }
            }
        }
    }

    /// Called when the pane switches away from Claude.
    func reset() {
        logger.info("ClaudeLogWatcher: reset (pane switched away from Claude)")
        fileURL = nil
        readOffset = 0
        filePinned = false
        awaitingNextTurn = false
        try? FileManager.default.removeItem(at: permissionSentinelURL)
        try? FileManager.default.removeItem(at: turnCompleteSentinelURL)
        try? FileManager.default.removeItem(at: claimFileURL)
        // Clean up legacy global sentinels (pre-session-scoped migration).
        try? FileManager.default.removeItem(at: Self.legacyPermissionSentinelURL)
        try? FileManager.default.removeItem(at: Self.legacyTurnCompleteSentinelURL)
        updatePlanArtifact(nil)
    }

    // MARK: - Private

    private func projectDir() -> URL? {
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
                filePinned = false
            }
            return
        }

        // Once pinned to a file, stick with it until reset().
        if filePinned, let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            return
        }

        // If we have a target session ID whose JSONL file exists, use it directly.
        if let targetSessionId {
            let target = dir.appendingPathComponent("\(targetSessionId).jsonl")
            if FileManager.default.fileExists(atPath: target.path) {
                pinToFile(target)
                return
            }
        }

        // Fallback: pick the newest unclaimed JSONL file.
        // Read claim files written by other watchers (govibe-*-jsonl-claim)
        // to avoid selecting a file another session is already reading.
        let claimedPaths = otherClaimedPaths()

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let candidates = contents
            .filter { $0.pathExtension == "jsonl" && !claimedPaths.contains($0.path) }
            .sorted {
                let aDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return aDate > bDate // newest first
            }

        guard let selected = candidates.first else {
            // If all files are claimed, fall back to newest overall.
            let allFiles = contents
                .filter { $0.pathExtension == "jsonl" }
                .max {
                    let aDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let bDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return aDate < bDate
                }
            if let allFiles {
                pinToFile(allFiles)
            } else if fileURL != nil {
                logger.info("ClaudeLogWatcher: no .jsonl files found in \(dir.path)")
                fileURL = nil
                filePinned = false
            }
            return
        }

        pinToFile(selected)
        resolveClaimConflicts()
    }

    private func pinToFile(_ url: URL) {
        guard url != fileURL else {
            if !filePinned { filePinned = true }
            return
        }
        let endOffset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        logger.info("ClaudeLogWatcher: pinned to \(url.lastPathComponent) at offset \(endOffset)")
        fileURL = url
        readOffset = endOffset
        filePinned = true
        // Write claim file so other watchers skip this file.
        try? url.path.write(to: claimFileURL, atomically: true, encoding: .utf8)
        let allArtifacts = existingPlanArtifacts(in: url)
        if !allArtifacts.isEmpty {
            onPlanArtifactsLoaded(allArtifacts)
        }
        updatePlanArtifact(allArtifacts.last)
        updateLastUserPrompt(existingLastUserPrompt(in: url))
    }

    /// Detects and resolves conflicts when two watchers race and claim the same file.
    /// Uses the claim file name (which encodes the tmux session name) as a deterministic
    /// tiebreaker: the lexicographically smaller name wins.
    private func resolveClaimConflicts() {
        guard let myPath = fileURL?.path else { return }
        let myName = claimFileURL.lastPathComponent

        for (name, path) in otherClaimedEntries() {
            if path == myPath, name < myName {
                // The other watcher has priority — yield and retry next poll.
                logger.info("ClaudeLogWatcher: claim conflict with \(name), yielding")
                fileURL = nil
                readOffset = 0
                filePinned = false
                try? FileManager.default.removeItem(at: claimFileURL)
                return
            }
        }
    }

    /// Reads claim files from other GoVibe watchers.
    /// Returns (claimFileName, claimedPath) pairs.
    private func otherClaimedEntries() -> [(String, String)] {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: claudeDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }
        var result: [(String, String)] = []
        for entry in entries where entry.lastPathComponent.hasPrefix("govibe-")
                                 && entry.lastPathComponent.hasSuffix("-jsonl-claim")
                                 && entry != claimFileURL {
            if let claimed = try? String(contentsOf: entry, encoding: .utf8) {
                result.append((entry.lastPathComponent, claimed.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return result
    }

    /// Returns paths claimed by other watchers.
    private func otherClaimedPaths() -> Set<String> {
        Set(otherClaimedEntries().map(\.1))
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
        return content.contains {
            $0["type"] as? String == "text" &&
            !($0["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func exitPlanModeArtifact(from message: [String: Any]?, uuid: String) -> TerminalPlanArtifact? {
        guard let content = message?["content"] as? [[String: Any]] else { return nil }
        for item in content {
            guard item["type"] as? String == "tool_use",
                  item["name"] as? String == "ExitPlanMode",
                  let input = item["input"] as? [String: Any] else { continue }

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
        existingPlanArtifacts(in: url).last
    }

    private func existingPlanArtifacts(in url: URL) -> [TerminalPlanArtifact] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var artifacts: [TerminalPlanArtifact] = []
        var currentArtifact: TerminalPlanArtifact?
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String
            let uuid = obj["uuid"] as? String
            let message = obj["message"] as? [String: Any]

            if type == "user", isExternalUserPrompt(message) {
                if let artifact = currentArtifact {
                    artifacts.append(artifact)
                    currentArtifact = nil
                }
                continue
            }

            if type == "assistant", let uuid {
                if let planArtifact = exitPlanModeArtifact(from: message, uuid: uuid) {
                    currentArtifact = planArtifact
                } else if let text = assistantText(from: message),
                          let planArtifact = TerminalPlanParser.parseArtifact(
                            assistant: "Claude", turnId: uuid, text: text) {
                    currentArtifact = planArtifact
                }
            }
        }
        if let artifact = currentArtifact {
            artifacts.append(artifact)
        }
        return artifacts
    }

    private func updatePlanArtifact(_ artifact: TerminalPlanArtifact?) {
        guard artifact != currentPlanArtifact else { return }
        currentPlanArtifact = artifact
        onPlanStateChanged(artifact)
    }

    private func userPromptText(from message: [String: Any]?) -> String? {
        guard let message else { return nil }
        if let content = message["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
        }
        guard let content = message["content"] as? [[String: Any]] else { return nil }
        let textParts = content.compactMap { item -> String? in
            guard item["type"] as? String == "text" else { return nil }
            return item["text"] as? String
        }
        let joined = textParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : String(joined.prefix(200))
    }

    private func existingLastUserPrompt(in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var prompt: String?
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "user"
            else { continue }
            let message = obj["message"] as? [String: Any]
            if isExternalUserPrompt(message) {
                prompt = userPromptText(from: message)
            }
        }
        return prompt
    }

    private func updateLastUserPrompt(_ prompt: String?) {
        guard let prompt, prompt != lastUserPrompt else { return }
        lastUserPrompt = prompt
        onLastUserPromptChanged(prompt)
    }
}

import Foundation

enum GeminiPushEvent: String {
    case awaitingApproval = "gemini_approval_required"
    case turnComplete     = "gemini_turn_complete"
}

/// Watches Gemini CLI sentinel files and session JSON for push notification triggers.
///
/// Unlike Claude/Codex (which use append-only JSONL), Gemini rewrites a single JSON
/// document. Completion and approval signals are delivered via sentinel files written
/// by hooks in ~/.gemini/settings.json, mirroring the Claude sentinel pattern.
///
/// Polling is driven externally — call `poll()` every second from the host session.
final class GeminiLogWatcher {
    /// Written by the Gemini `AfterAgent` hook.
    static let turnCompleteSentinelURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/govibe-turn-complete-pending")

    /// Written by the Gemini `Notification` / ToolPermission hook.
    static let permissionSentinelURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/govibe-permission-pending")

    private let chatsRoot: URL
    private let logger: HostLogger
    private var fileURL: URL?
    private var lastFileModDate: Date?
    private var lastSeenMessageCount: Int = 0
    private var awaitingNextTurn = false
    private var currentPlanArtifact: TerminalPlanArtifact?

    let onTurnComplete: (GeminiPushEvent) -> Void
    let onPlanStateChanged: (TerminalPlanArtifact?) -> Void

    init(
        logger: HostLogger,
        onTurnComplete: @escaping (GeminiPushEvent) -> Void,
        onPlanStateChanged: @escaping (TerminalPlanArtifact?) -> Void
    ) {
        self.logger = logger
        self.chatsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/tmp")
        self.onTurnComplete = onTurnComplete
        self.onPlanStateChanged = onPlanStateChanged
    }

    /// Called every second by `TerminalHostSession.pollPaneProgram()` while Gemini is active.
    func poll() {
        // Check permission sentinel — fires before turn-complete so approval takes priority.
        let permPath = Self.permissionSentinelURL.path
        if !awaitingNextTurn, FileManager.default.fileExists(atPath: permPath) {
            logger.info("GeminiLogWatcher: permission sentinel detected, firing approval push")
            try? FileManager.default.removeItem(atPath: permPath)
            awaitingNextTurn = true
            onTurnComplete(.awaitingApproval)
        }

        // Check turn-complete sentinel.
        let turnPath = Self.turnCompleteSentinelURL.path
        if !awaitingNextTurn, FileManager.default.fileExists(atPath: turnPath) {
            logger.info("GeminiLogWatcher: turn-complete sentinel detected, firing turn-complete push")
            try? FileManager.default.removeItem(atPath: turnPath)
            awaitingNextTurn = true
            onTurnComplete(.turnComplete)
        }

        // Refresh session file pointer.
        refreshFileIfNeeded()
        guard let url = fileURL else { return }

        // Skip full JSON parse when file hasn't changed.
        let modDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard modDate != lastFileModDate else { return }
        lastFileModDate = modDate

        // Read and parse the mutable session JSON.
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]] else {
            return
        }

        let newMessages = messages.count > lastSeenMessageCount
            ? Array(messages[lastSeenMessageCount...])
            : []
        lastSeenMessageCount = messages.count

        for message in newMessages {
            if (message["type"] as? String) == "user" {
                if awaitingNextTurn {
                    logger.info("GeminiLogWatcher: user turn detected, clearing awaitingNextTurn")
                }
                awaitingNextTurn = false
                updatePlanArtifact(nil)
            }
        }
    }

    /// Called when the pane switches away from Gemini. Cleans up sentinels and resets state.
    func reset() {
        logger.info("GeminiLogWatcher: reset (pane switched away from Gemini)")
        fileURL = nil
        lastFileModDate = nil
        lastSeenMessageCount = 0
        awaitingNextTurn = false
        try? FileManager.default.removeItem(at: Self.turnCompleteSentinelURL)
        try? FileManager.default.removeItem(at: Self.permissionSentinelURL)
        updatePlanArtifact(nil)
    }

    // MARK: - Private

    /// Scans ~/.gemini/tmp/*/chats/session-*.json and picks the file with the most
    /// recent modification date. No cwd→project mapping is needed since only one
    /// Gemini session runs at a time.
    private func refreshFileIfNeeded() {
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: chatsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        var candidates: [URL] = []
        for projectDir in projectDirs {
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let chatsDir = projectDir.appendingPathComponent("chats")
            guard let chatContents = try? FileManager.default.contentsOfDirectory(
                at: chatsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }
            let sessionFiles = chatContents.filter {
                $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "json"
            }
            candidates.append(contentsOf: sessionFiles)
        }

        let newest = candidates.max { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate < bDate
        }

        guard let newest else {
            if fileURL != nil {
                logger.info("GeminiLogWatcher: no session files found in \(chatsRoot.path)")
                fileURL = nil
                lastFileModDate = nil
                lastSeenMessageCount = 0
            }
            return
        }

        if newest != fileURL {
            logger.info("GeminiLogWatcher: watching \(newest.lastPathComponent)")
            fileURL = newest
            lastFileModDate = nil
            lastSeenMessageCount = 0
        }
    }

    private func updatePlanArtifact(_ artifact: TerminalPlanArtifact?) {
        guard artifact != currentPlanArtifact else { return }
        currentPlanArtifact = artifact
        onPlanStateChanged(artifact)
    }
}

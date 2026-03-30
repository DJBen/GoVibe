import Foundation

enum GeminiPushEvent: String {
    case awaitingApproval = "gemini_approval_required"
    case turnComplete     = "gemini_turn_complete"
}

/// Watches Gemini CLI sentinel files for push notification triggers.
///
/// Both signals are entirely hook-driven via ~/.gemini/settings.json:
/// - Turn-complete: the `AfterAgent` hook writes `govibe-turn-complete-pending`.
/// - Approval-required: the `Notification`/ToolPermission hook writes `govibe-permission-pending`.
///
/// Sentinels are one-shot — consumed (deleted) immediately on detection — so no
/// deduplication state is needed. Polling is driven externally; call `poll()` every
/// second from the host session.
final class GeminiLogWatcher {
    /// Session-scoped sentinel written by the Gemini `AfterAgent` hook.
    private let turnCompleteSentinelURL: URL
    /// Session-scoped sentinel written by the Gemini `Notification`/ToolPermission hook.
    private let permissionSentinelURL: URL

    /// Legacy global sentinel paths (no session prefix) cleaned up during reset as a migration step.
    private static let legacyTurnCompleteSentinelURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/govibe-turn-complete-pending")
    private static let legacyPermissionSentinelURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/govibe-permission-pending")

    private static let geminiRoot: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini")

    private let logger: HostLogger
    private var cwd: String
    private var lastUserPrompt: String?
    private var lastChatFileURL: URL?
    private var lastChatModDate: Date?
    private var lastChatCheckAt: Date?
    private static let chatCheckInterval: TimeInterval = 5

    let onTurnComplete: (GeminiPushEvent) -> Void
    let onLastUserPromptChanged: (String) -> Void

    init(
        tmuxSessionName: String,
        cwd: String,
        logger: HostLogger,
        onTurnComplete: @escaping (GeminiPushEvent) -> Void,
        onLastUserPromptChanged: @escaping (String) -> Void
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let prefix = "govibe-\(tmuxSessionName)-"
        self.permissionSentinelURL = home.appendingPathComponent(".gemini/\(prefix)permission-pending")
        self.turnCompleteSentinelURL = home.appendingPathComponent(".gemini/\(prefix)turn-complete-pending")
        self.cwd = cwd
        self.logger = logger
        self.onTurnComplete = onTurnComplete
        self.onLastUserPromptChanged = onLastUserPromptChanged
    }

    func updateCwd(_ newCwd: String) {
        guard newCwd != cwd else { return }
        logger.info("GeminiLogWatcher: cwd updated \(cwd) → \(newCwd)")
        cwd = newCwd
        lastChatFileURL = nil
        lastChatModDate = nil
        lastChatCheckAt = nil
    }

    /// Called every second by `TerminalHostSession.pollPaneProgram()` while Gemini is active.
    func poll() {
        let permPath = permissionSentinelURL.path
        let legacyPermPath = Self.legacyPermissionSentinelURL.path
        
        if FileManager.default.fileExists(atPath: permPath) {
            logger.info("GeminiLogWatcher: permission sentinel detected at \(permPath), firing approval push")
            try? FileManager.default.removeItem(atPath: permPath)
            onTurnComplete(.awaitingApproval)
        } else if FileManager.default.fileExists(atPath: legacyPermPath) {
            logger.info("GeminiLogWatcher: legacy permission sentinel detected, firing approval push")
            try? FileManager.default.removeItem(atPath: legacyPermPath)
            onTurnComplete(.awaitingApproval)
        }

        let turnPath = turnCompleteSentinelURL.path
        let legacyTurnPath = Self.legacyTurnCompleteSentinelURL.path
        
        if FileManager.default.fileExists(atPath: turnPath) {
            logger.info("GeminiLogWatcher: turn-complete sentinel detected at \(turnPath), firing turn-complete push")
            try? FileManager.default.removeItem(atPath: turnPath)
            onTurnComplete(.turnComplete)
        } else if FileManager.default.fileExists(atPath: legacyTurnPath) {
            logger.info("GeminiLogWatcher: legacy turn-complete sentinel detected, firing turn-complete push")
            try? FileManager.default.removeItem(atPath: legacyTurnPath)
            onTurnComplete(.turnComplete)
        }

        refreshChatIfNeeded()
    }

    /// Called when the pane switches away from Gemini. Cleans up any stale sentinels.
    func reset() {
        logger.info("GeminiLogWatcher: reset (pane switched away from Gemini)")
        try? FileManager.default.removeItem(at: turnCompleteSentinelURL)
        try? FileManager.default.removeItem(at: permissionSentinelURL)
        // Clean up legacy global sentinels (pre-session-scoped migration).
        try? FileManager.default.removeItem(at: Self.legacyTurnCompleteSentinelURL)
        try? FileManager.default.removeItem(at: Self.legacyPermissionSentinelURL)
    }

    // MARK: - Chat file reading

    private func refreshChatIfNeeded() {
        if let lastCheck = lastChatCheckAt,
           Date().timeIntervalSince(lastCheck) < Self.chatCheckInterval {
            return
        }
        lastChatCheckAt = Date()

        guard let chatURL = latestChatFile() else { return }
        let modDate = (try? chatURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast

        if chatURL == lastChatFileURL, modDate == lastChatModDate { return }
        lastChatFileURL = chatURL
        lastChatModDate = modDate

        if let prompt = extractLastUserPrompt(from: chatURL), prompt != lastUserPrompt {
            lastUserPrompt = prompt
            onLastUserPromptChanged(prompt)
        }
    }

    private func geminiProjectName() -> String? {
        let projectsFile = Self.geminiRoot.appendingPathComponent("projects.json")
        guard let data = try? Data(contentsOf: projectsFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = obj["projects"] as? [String: String]
        else { return nil }
        return projects[cwd]
    }

    private func latestChatFile() -> URL? {
        guard let projectName = geminiProjectName() else { return nil }
        let chatsDir = Self.geminiRoot
            .appendingPathComponent("tmp")
            .appendingPathComponent(projectName)
            .appendingPathComponent("chats")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: chatsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        return contents
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("session-") }
            .max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
    }

    private func extractLastUserPrompt(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = obj["messages"] as? [[String: Any]]
        else { return nil }

        for message in messages.reversed() {
            guard message["type"] as? String == "user" else { continue }
            let content = message["content"]
            if let parts = content as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return String(trimmed.prefix(200)) }
                    }
                }
            } else if let text = content as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.prefix(200)) }
            }
        }
        return nil
    }
}

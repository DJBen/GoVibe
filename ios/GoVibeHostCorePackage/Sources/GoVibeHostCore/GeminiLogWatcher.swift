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
    /// Written by the Gemini `AfterAgent` hook.
    static let turnCompleteSentinelURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/govibe-turn-complete-pending")

    /// Written by the Gemini `Notification`/ToolPermission hook.
    static let permissionSentinelURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/govibe-permission-pending")

    private let logger: HostLogger
    let onTurnComplete: (GeminiPushEvent) -> Void

    init(logger: HostLogger, onTurnComplete: @escaping (GeminiPushEvent) -> Void) {
        self.logger = logger
        self.onTurnComplete = onTurnComplete
    }

    /// Called every second by `TerminalHostSession.pollPaneProgram()` while Gemini is active.
    func poll() {
        let permPath = Self.permissionSentinelURL.path
        if FileManager.default.fileExists(atPath: permPath) {
            logger.info("GeminiLogWatcher: permission sentinel detected, firing approval push")
            try? FileManager.default.removeItem(atPath: permPath)
            onTurnComplete(.awaitingApproval)
        }

        let turnPath = Self.turnCompleteSentinelURL.path
        if FileManager.default.fileExists(atPath: turnPath) {
            logger.info("GeminiLogWatcher: turn-complete sentinel detected, firing turn-complete push")
            try? FileManager.default.removeItem(atPath: turnPath)
            onTurnComplete(.turnComplete)
        }
    }

    /// Called when the pane switches away from Gemini. Cleans up any stale sentinels.
    func reset() {
        logger.info("GeminiLogWatcher: reset (pane switched away from Gemini)")
        try? FileManager.default.removeItem(at: Self.turnCompleteSentinelURL)
        try? FileManager.default.removeItem(at: Self.permissionSentinelURL)
    }
}

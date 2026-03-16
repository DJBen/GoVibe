import Foundation

/// Watches Claude's JSONL conversation log and fires `onTurnComplete` whenever
/// Claude is waiting for user input — either after `end_turn` or after a `tool_use`
/// that goes unanswered for `toolUseIdleThreshold` seconds (i.e. awaiting approval).
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

    /// Set when a tool_use is seen; cleared when any new JSONL line appears.
    /// If the date is more than `toolUseIdleThreshold` seconds old on the next
    /// poll with no new lines, we fire a push (Claude is likely awaiting approval).
    private var pendingToolUseSince: Date?
    private static let toolUseIdleThreshold: TimeInterval = 8

    let onTurnComplete: () -> Void

    init(cwd: String, logger: HostLogger, onTurnComplete: @escaping () -> Void) {
        self.cwd = cwd
        self.logger = logger
        self.projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        self.onTurnComplete = onTurnComplete
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
        let newLines = readNewLines(from: url)

        if newLines.isEmpty {
            // No new lines — check if a pending tool_use has gone idle long enough.
            if let since = pendingToolUseSince,
               !awaitingNextTurn,
               Date().timeIntervalSince(since) >= Self.toolUseIdleThreshold {
                logger.info("ClaudeLogWatcher: tool_use idle for \(Int(Self.toolUseIdleThreshold))s, awaiting approval — firing push")
                pendingToolUseSince = nil
                awaitingNextTurn = true
                onTurnComplete()
            }
            return
        }

        // New lines arrived — cancel any pending tool_use timer.
        pendingToolUseSince = nil

        for line in newLines {
            guard
                let data = line.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String
            let uuid = obj["uuid"] as? String
            let message = obj["message"] as? [String: Any]
            let stopReason = message?["stop_reason"] as? String

            if type == "user" {
                // User replied (or tool result arrived) — ready for next notification.
                if awaitingNextTurn {
                    logger.info("ClaudeLogWatcher: user turn detected, ready for next end_turn")
                }
                awaitingNextTurn = false
                pendingToolUseSince = nil
            }

            if type == "assistant", let stopReason {
                logger.info("ClaudeLogWatcher: assistant stop_reason=\(stopReason) uuid=\(uuid ?? "nil") awaitingNextTurn=\(awaitingNextTurn)")
            }

            if type == "assistant", stopReason == "tool_use", !awaitingNextTurn {
                // Start the idle timer — if no new lines arrive within the threshold,
                // Claude is likely waiting for the user to approve this tool call.
                pendingToolUseSince = Date()
            }

            if type == "assistant",
               stopReason == "end_turn",
               let uuid,
               uuid != lastNotifiedUUID,
               !awaitingNextTurn {
                logger.info("ClaudeLogWatcher: end_turn detected, firing push notification")
                pendingToolUseSince = nil
                lastNotifiedUUID = uuid
                awaitingNextTurn = true
                onTurnComplete()
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
        pendingToolUseSince = nil
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
            pendingToolUseSince = nil
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
}

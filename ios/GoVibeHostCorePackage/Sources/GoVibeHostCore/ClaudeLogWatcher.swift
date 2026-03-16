import Foundation

/// Watches Claude's JSONL conversation log and fires `onTurnComplete` whenever
/// Claude finishes a turn (`stop_reason == "end_turn"`).
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
                // User replied — allow the next end_turn to fire a notification.
                if awaitingNextTurn {
                    logger.info("ClaudeLogWatcher: user turn detected, ready for next end_turn")
                }
                awaitingNextTurn = false
            }

            if type == "assistant", let stopReason {
                logger.info("ClaudeLogWatcher: assistant stop_reason=\(stopReason) uuid=\(uuid ?? "nil") awaitingNextTurn=\(awaitingNextTurn)")
            }

            if type == "assistant",
               stopReason == "end_turn",
               let uuid,
               uuid != lastNotifiedUUID,
               !awaitingNextTurn {
                logger.info("ClaudeLogWatcher: end_turn detected, firing push notification")
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

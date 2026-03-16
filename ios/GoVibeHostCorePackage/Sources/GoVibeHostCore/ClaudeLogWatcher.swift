import Foundation

/// Watches Claude's JSONL conversation log and fires `onTurnComplete` whenever
/// Claude finishes a turn (`stop_reason == "end_turn"`).
///
/// Polling is driven externally — call `poll()` every second from the host session.
final class ClaudeLogWatcher {
    private let projectsRoot: URL
    private var cwd: String
    private var fileURL: URL?
    private var readOffset: UInt64 = 0
    private var lastNotifiedUUID: String?
    private var awaitingNextTurn = false

    let onTurnComplete: () -> Void

    init(cwd: String, onTurnComplete: @escaping () -> Void) {
        self.cwd = cwd
        self.projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        self.onTurnComplete = onTurnComplete
    }

    /// Update the working directory (e.g. when the tmux pane's cwd changes).
    func updateCwd(_ newCwd: String) {
        guard newCwd != cwd else { return }
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
                awaitingNextTurn = false
            }

            if type == "assistant",
               stopReason == "end_turn",
               let uuid,
               uuid != lastNotifiedUUID,
               !awaitingNextTurn {
                lastNotifiedUUID = uuid
                awaitingNextTurn = true
                onTurnComplete()
            }
        }
    }

    /// Called when the pane switches away from Claude.
    func reset() {
        fileURL = nil
        readOffset = 0
        lastNotifiedUUID = nil
        awaitingNextTurn = false
    }

    // MARK: - Private

    private func projectDir() -> URL? {
        // Claude derives the project dir name from the cwd:
        //   strip the leading '/', then replace every '/' with '-'
        // e.g. "/Users/sihaolu/Developments/GoVibe" → "-Users-sihaolu-Developments-GoVibe"
        var dirName = cwd
        if dirName.hasPrefix("/") {
            dirName = String(dirName.dropFirst())
        }
        dirName = dirName.replacingOccurrences(of: "/", with: "-")
        let dir = projectsRoot.appendingPathComponent(dirName)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return dir
    }

    private func refreshFileIfNeeded() {
        guard let dir = projectDir() else {
            fileURL = nil
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
            fileURL = nil
            return
        }

        if newest != fileURL {
            fileURL = newest
            readOffset = 0
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

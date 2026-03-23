import Darwin
import Foundation

public final class PtySession: @unchecked Sendable {
    private let logger: HostLogger
    private let shellPath: String
    public let tmuxSessionName: String?
    private let ioQueue = DispatchQueue(label: "dev.govibe.host.pty", qos: .userInitiated)

    private var masterFd: Int32 = -1
    private var childPid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var waitTask: Task<Void, Never>?
    private var tmuxCopyModeActive = false

    public var onOutputData: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

    public init(shellPath: String, tmuxSessionName: String? = nil, logger: HostLogger) {
        self.shellPath = shellPath
        self.tmuxSessionName = tmuxSessionName
        self.logger = logger
    }

    public static func listTmuxSessions() -> [String] {
        guard let tmuxPath = resolveTmux() else { return [] }
        return captureProcessOutput(executable: tmuxPath, arguments: ["list-sessions", "-F", "#{session_name}"])?
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    public static func resolveTmux() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/opt/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        for candidate in candidates {
            if isFilePresent(atPath: candidate) {
                return candidate
            }

            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            if resolved != candidate, isFilePresent(atPath: resolved) {
                return resolved
            }
        }

        if let discovered = captureProcessOutput(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v tmux 2>/dev/null"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
           !discovered.isEmpty,
           isFilePresent(atPath: discovered) {
            return discovered
        }

        return nil
    }

    private static func isFilePresent(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return true
    }

    private static func captureProcessOutput(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    public func start() throws {
        // Resolve tmux path BEFORE fork — resolveTmux() uses FileManager/Process
        // which are NOT async-signal-safe and crash in forked child processes.
        let resolvedTmuxPath: String? = tmuxSessionName != nil ? Self.resolveTmux() : nil

        var master: Int32 = -1
        var winsz = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &winsz)
        if pid < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        if pid == 0 {
            // CHILD — only async-signal-safe functions (setenv, execv, _exit, etc.)
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            setenv("LC_ALL", "en_US.UTF-8", 1)
            setenv("LC_CTYPE", "en_US.UTF-8", 1)
            setenv("COLORTERM", "truecolor", 1)
            if let sessionName = tmuxSessionName, let tmuxPath = resolvedTmuxPath {
                setenv("GOVIBE_TMUX_SESSION", sessionName, 1)
                setenv("GOVIBE_TMUX_BIN", tmuxPath, 1)
                let cmd = "exec \"$GOVIBE_TMUX_BIN\" new-session -A -s \"$GOVIBE_TMUX_SESSION\""
                var cArgs: [UnsafeMutablePointer<CChar>?] = [
                    strdup("/bin/zsh"), strdup("-lc"), strdup(cmd), nil
                ]
                execv("/bin/zsh", &cArgs)
            } else {
                var cArgs: [UnsafeMutablePointer<CChar>?] = [
                    strdup(shellPath), strdup("-l"), nil
                ]
                execv(shellPath, &cArgs)
            }
            _exit(127)
        }

        childPid = pid
        masterFd = master
        logger.info("PTY started pid=\(childPid)")
        if let sessionName = tmuxSessionName {
            logger.info("PTY tmux session configured: \(sessionName)")
            logger.info("PTY tmux path resolved: \(resolvedTmuxPath ?? "<nil>")")
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.readAvailableData()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.masterFd >= 0 {
                close(self.masterFd)
                self.masterFd = -1
            }
        }
        readSource = source
        source.resume()

        waitTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            _ = waitpid(self.childPid, &status, 0)
            self.logger.info("PTY child exited status=\(status)")
            self.onExit?(status)
        }
    }

    private func readAvailableData() {
        guard masterFd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(masterFd, &buffer, buffer.count)
            if n > 0 {
                onOutputData?(Data(buffer.prefix(Int(n))))
                continue
            }
            if n == 0 {
                readSource?.cancel()
                return
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            logger.error("PTY read failed errno=\(errno)")
            readSource?.cancel()
            return
        }
    }

    public func writeInputData(_ data: Data) {
        guard masterFd >= 0 else { return }

        if tmuxCopyModeActive, let session = tmuxSessionName, let tmuxPath = Self.resolveTmux() {
            _ = runProcess(executable: tmuxPath, arguments: ["send-keys", "-t", session, "-X", "cancel"])
            tmuxCopyModeActive = false
        }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let wrote = write(masterFd, base.advanced(by: sent), raw.count - sent)
                if wrote > 0 {
                    sent += wrote
                    continue
                }
                if wrote < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    usleep(2_000)
                    continue
                }
                logger.error("PTY write failed errno=\(errno)")
                return
            }
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard masterFd >= 0 else { return }
        var winsz = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        if ioctl(masterFd, TIOCSWINSZ, &winsz) != 0 {
            logger.error("PTY resize failed errno=\(errno)")
        }
    }

    public func scroll(lines: Int) {
        guard lines != 0 else { return }

        if let session = tmuxSessionName, let tmuxPath = Self.resolveTmux() {
            let amount = max(1, min(50, abs(lines)))
            if lines > 0 {
                _ = runProcess(executable: tmuxPath, arguments: ["copy-mode", "-t", session])
                tmuxCopyModeActive = true
                _ = runProcess(executable: tmuxPath, arguments: ["send-keys", "-t", session, "-N", String(amount), "Up"])
            } else {
                _ = runProcess(executable: tmuxPath, arguments: ["send-keys", "-t", session, "-N", String(amount), "Down"])
            }
            return
        }

        let sequence: [UInt8] = lines > 0 ? [0x1B, 0x5B, 0x35, 0x7E] : [0x1B, 0x5B, 0x36, 0x7E]
        for _ in 0..<max(1, min(10, abs(lines))) {
            writeInputData(Data(sequence))
        }
    }

    public func cancelScrollMode() {
        guard let session = tmuxSessionName, let tmuxPath = Self.resolveTmux() else { return }
        _ = runProcess(executable: tmuxPath, arguments: ["send-keys", "-t", session, "-X", "cancel"])
        tmuxCopyModeActive = false
    }

    @discardableResult
    private func runProcess(executable: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            logger.error("Process failed (\(arguments.joined(separator: " "))): \(error.localizedDescription)")
            return -1
        }
    }

    public func stop() {
        readSource?.cancel()
        readSource = nil

        if childPid > 0 {
            kill(childPid, SIGTERM)
        }
        waitTask?.cancel()
        waitTask = nil
    }
}

import Darwin
import Foundation

final class PtySession: @unchecked Sendable {
    private let logger: Logger
    private let shellPath: String
    let tmuxSessionName: String?
    private let ioQueue = DispatchQueue(label: "dev.govibe.maccli.pty", qos: .userInitiated)

    private var masterFd: Int32 = -1
    private var childPid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var waitTask: Task<Void, Never>?
    private var tmuxCopyModeActive = false

    var onOutputData: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    init(shellPath: String, tmuxSessionName: String? = nil, logger: Logger) {
        self.shellPath = shellPath
        self.tmuxSessionName = tmuxSessionName
        self.logger = logger
    }

    static func resolveTmux() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",  // Apple Silicon Homebrew
            "/usr/local/bin/tmux",     // Intel Homebrew
            "/usr/bin/tmux"            // system
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() throws {
        var master: Int32 = -1
        var winsz = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &winsz)
        if pid < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        if pid == 0 {
            setenv("TERM", "xterm-256color", 1)
            // Ensure shell/apps running in this PTY emit UTF-8 glyphs consistently.
            setenv("LANG", "en_US.UTF-8", 1)
            setenv("LC_ALL", "en_US.UTF-8", 1)
            setenv("LC_CTYPE", "en_US.UTF-8", 1)
            setenv("COLORTERM", "truecolor", 1)
            let args: [String]
            let execPath: String
            if let sessionName = tmuxSessionName, let tmux = Self.resolveTmux() {
                execPath = tmux
                args = [tmux, "new-session", "-A", "-s", sessionName]
            } else {
                execPath = shellPath
                args = [shellPath, "-l"]
            }

            var cArgs = args.map { strdup($0) }
            cArgs.append(nil)
            execv(execPath, &cArgs)
            _exit(127)
        }

        childPid = pid
        masterFd = master
        logger.info("PTY started pid=\(childPid)")

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

    func writeInputData(_ data: Data) {
        guard masterFd >= 0 else { return }

        // If remote scrolling placed tmux into copy-mode, leave it before forwarding
        // user keystrokes so typing resumes in the live shell prompt.
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

    func resize(cols: Int, rows: Int) {
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

    func scroll(lines: Int) {
        guard lines != 0 else { return }

        // Prefer explicit tmux scrollback control when running in tmux.
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

        // Fallback for non-tmux sessions: Page Up/Page Down.
        let sequence: [UInt8] = lines > 0 ? [0x1B, 0x5B, 0x35, 0x7E] : [0x1B, 0x5B, 0x36, 0x7E]
        for _ in 0..<max(1, min(10, abs(lines))) {
            writeInputData(Data(sequence))
        }
    }

    func cancelScrollMode() {
        guard let session = tmuxSessionName,
              let tmuxPath = Self.resolveTmux() else { return }
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

    func stop() {
        readSource?.cancel()
        readSource = nil

        if childPid > 0 {
            kill(childPid, SIGTERM)
        }
        waitTask?.cancel()
        waitTask = nil
    }
}

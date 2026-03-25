import Foundation

public enum HostSessionRuntimeEvent: Sendable {
    case stateChanged(HostedSessionState, Date?, String?)
    case lastUserPromptChanged(String)
}

public final class TerminalHostSession: @unchecked Sendable, ManagedHostRuntime {
    private static let peerStaleTimeout: TimeInterval = 120

    private let hostId: String
    private let macDeviceId: String
    private let sessionDisplayName: String
    private let pty: PtySession
    private let logger: HostLogger
    private let bridge: RelayTransport
    private let relayBase: String
    private let eventHandler: @Sendable (HostSessionRuntimeEvent) -> Void

    private let snapshotLock = NSLock()
    private let stateLock = NSLock()
    private var snapshotWorkItem: DispatchWorkItem?
    private var programTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastPaneProgram: String = ""
    private var retirementSent = false
    private var activePeerCount = 0
    private var lastPeerActivityAt: Date?
    private var started = false
    private var running = false
    private var stopSignalSent = false
    private let stopSemaphore = DispatchSemaphore(value: 0)

    private var claudeLogWatcher: ClaudeLogWatcher?
    private var codexLogWatcher: CodexLogWatcher?
    private var geminiLogWatcher: GeminiLogWatcher?
    private var currentPlanArtifact: TerminalPlanArtifact?

    public init(
        hostId: String,
        config: TerminalSessionConfig,
        relayBase: String,
        logger: HostLogger,
        eventHandler: @escaping @Sendable (HostSessionRuntimeEvent) -> Void = { _ in }
    ) {
        self.hostId = hostId
        self.macDeviceId = "\(hostId)-\(config.sessionId)"
        self.sessionDisplayName = config.tmuxSessionName
        self.pty = PtySession(shellPath: config.shellPath, tmuxSessionName: config.tmuxSessionName, logger: logger)
        self.logger = logger
        self.bridge = RelayTransport(logger: logger)
        self.relayBase = relayBase
        self.eventHandler = eventHandler
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !started else { return }
        started = true
        running = true
        eventHandler(.stateChanged(.starting, nil, nil))

        pty.onOutputData = { [weak self] chunk in
            self?.bridge.sendTerminalOutput(chunk)
        }
        bridge.onInputData = { [weak self] input in
            self?.pty.writeInputData(input)
        }
        bridge.onResize = { [weak self] cols, rows in
            guard let self else { return }
            self.pty.resize(cols: cols, rows: rows)
            self.scheduleSnapshotReplay()
        }
        bridge.onScroll = { [weak self] lines in
            self?.pty.scroll(lines: lines)
        }
        bridge.onScrollCancel = { [weak self] in
            self?.pty.cancelScrollMode()
            self?.scheduleSnapshotReplay()
        }
        bridge.onPeerJoined = { [weak self] in
            self?.recordPeerJoin()
            self?.scheduleSnapshotReplay()
            self?.sendCurrentPlanState()
        }
        bridge.onPeerLeft = { [weak self] in
            self?.recordPeerLeave()
        }
        // Peer liveness is detected via peer_joined/peer_left from the relay
        // and real data messages — no periodic heartbeat needed.
        pty.onExit = { [weak self] _ in
            self?.sendPeerRetiredIfNeeded(reason: "pty_exit")
            self?.eventHandler(.stateChanged(.stopped, self?.lastPeerActivityAt, nil))
            self?.signalStopIfNeeded()
        }

        let sessionName = pty.tmuxSessionName ?? ""
        let promptHandler: (String) -> Void = { [weak self] prompt in
            self?.eventHandler(.lastUserPromptChanged(prompt))
        }
        claudeLogWatcher = ClaudeLogWatcher(
            tmuxSessionName: sessionName,
            cwd: NSHomeDirectory(),
            logger: logger,
            onTurnComplete: { [weak self] event in
                self?.bridge.sendPushNotify(event: event.rawValue, sessionName: self?.sessionDisplayName)
            },
            onPlanStateChanged: { [weak self] artifact in
                self?.setPlanArtifact(artifact)
            },
            onLastUserPromptChanged: promptHandler
        )
        codexLogWatcher = CodexLogWatcher(
            cwd: NSHomeDirectory(),
            logger: logger,
            onTurnComplete: { [weak self] event in
                self?.bridge.sendPushNotify(event: event.rawValue, sessionName: self?.sessionDisplayName)
            },
            onPlanStateChanged: { [weak self] artifact in
                self?.setPlanArtifact(artifact)
            },
            onLastUserPromptChanged: promptHandler
        )
        geminiLogWatcher = GeminiLogWatcher(
            tmuxSessionName: sessionName,
            cwd: NSHomeDirectory(),
            logger: logger,
            onTurnComplete: { [weak self] event in
                self?.bridge.sendPushNotify(event: event.rawValue, sessionName: self?.sessionDisplayName)
            },
            onLastUserPromptChanged: promptHandler
        )
        bridge.start(room: macDeviceId, hostId: hostId, relayBase: relayBase)
        try pty.start()
        startProgramPolling()
        startPeerWatchdog()
        eventHandler(.stateChanged(.waitingForPeer, nil, nil))
    }

    public func runUntilStopped() throws {
        try start()
        waitUntilStopped()
    }

    public func waitUntilStopped() {
        stopSemaphore.wait()
    }

    public func stop() {
        stateLock.lock()
        running = false
        stateLock.unlock()
        sendPeerRetiredIfNeeded(reason: "stopped")
        programTimer?.cancel()
        heartbeatTimer?.cancel()
        setPlanArtifact(nil)
        bridge.stop()
        pty.stop()
        eventHandler(.stateChanged(.stopped, lastPeerActivityAt, nil))
        signalStopIfNeeded()
    }

    public func remove() {
        stop()
        if let sessionName = pty.tmuxSessionName, let tmuxPath = PtySession.resolveTmux() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tmuxPath)
            p.arguments = ["kill-session", "-t", sessionName]
            try? p.run()
        }
    }

    private func signalStopIfNeeded() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopSignalSent else { return }
        stopSignalSent = true
        stopSemaphore.signal()
    }

    private func recordPeerActivity() {
        lastPeerActivityAt = .now
        eventHandler(.stateChanged(.running, lastPeerActivityAt, nil))
    }

    private func recordPeerJoin() {
        activePeerCount += 1
        recordPeerActivity()
    }

    private func recordPeerLeave() {
        activePeerCount = max(0, activePeerCount - 1)
        if activePeerCount == 0 {
            eventHandler(.stateChanged(.waitingForPeer, lastPeerActivityAt, nil))
        } else {
            eventHandler(.stateChanged(.running, lastPeerActivityAt, nil))
        }
    }

    private func scheduleSnapshotReplay() {
        snapshotLock.lock()
        snapshotWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.replayViaTmux()
        }
        snapshotWorkItem = item
        snapshotLock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    private func replayViaTmux() {
        guard let tmuxSessionName = pty.tmuxSessionName else {
            logger.info("Skipping tmux replay: tmuxSessionName is nil")
            return
        }

        guard let tmuxPath = PtySession.resolveTmux() else {
            logger.info("Skipping tmux replay: tmux binary not found in known paths")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["capture-pane", "-p", "-e", "-t", tmuxSessionName]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            logger.info("Running tmux capture-pane for session '\(tmuxSessionName)' via \(tmuxPath)")
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let stderrData = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                logger.error("tmux capture-pane exited \(process.terminationStatus)\(stderrText.isEmpty ? "" : ": \(stderrText)")")
                return
            }
            let captured = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !captured.isEmpty else {
                logger.info("tmux capture-pane returned empty output, skipping snapshot")
                return
            }
            let normalizedSnapshot = normalizeSnapshotLineEndings(captured)
            logger.info("Replaying tmux snapshot (\(normalizedSnapshot.count) bytes) to new peer")
            bridge.sendSnapshot(normalizedSnapshot)
            if !lastPaneProgram.isEmpty {
                bridge.sendPaneProgram(lastPaneProgram)
            }
            sendCurrentPlanState()
        } catch {
            logger.error("tmux capture-pane failed: \(error.localizedDescription)")
        }
    }

    private func normalizeSnapshotLineEndings(_ payload: Data) -> Data {
        var normalized = Data()
        normalized.reserveCapacity(payload.count + 32)
        var previousByte: UInt8?
        for byte in payload {
            if byte == 0x0A, previousByte != 0x0D {
                normalized.append(0x0D)
            }
            normalized.append(byte)
            previousByte = byte
        }
        return normalized
    }

    private func startProgramPolling() {
        guard pty.tmuxSessionName != nil, PtySession.resolveTmux() != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.pollPaneProgram() }
        timer.resume()
        programTimer = timer
    }

    private func startPeerWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let lastPeerActivityAt = self.lastPeerActivityAt,
               Date().timeIntervalSince(lastPeerActivityAt) > Self.peerStaleTimeout {
                self.activePeerCount = 0
                self.eventHandler(.stateChanged(.stale, lastPeerActivityAt, nil))
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func pollPaneProgram() {
        guard let sessionName = pty.tmuxSessionName,
              let tmuxPath = PtySession.resolveTmux() else { return }
        let name = currentPaneProgramName(sessionName: sessionName, tmuxPath: tmuxPath)
        if !name.isEmpty, name != lastPaneProgram {
            setPlanArtifact(nil)
            lastPaneProgram = name
            bridge.sendPaneProgram(name)
            logger.info("Pane program changed: \(name)")
            if name != "Claude" {
                claudeLogWatcher?.reset()
            }
            if name != "Codex" {
                codexLogWatcher?.reset()
            }
            if name != "Gemini" {
                geminiLogWatcher?.reset()
            }
            if name == "Claude" || name == "Codex" || name == "Gemini" {
                // Agent just became active — update the watcher's cwd from the tmux pane.
                if let paneCwd = runProcessCaptureOutput(
                    executable: tmuxPath,
                    arguments: ["display-message", "-p", "-t", sessionName, "#{pane_current_path}"]
                ) {
                    if name == "Claude" {
                        claudeLogWatcher?.updateCwd(paneCwd)
                    } else if name == "Codex" {
                        codexLogWatcher?.updateCwd(paneCwd)
                    } else {
                        geminiLogWatcher?.updateCwd(paneCwd)
                    }
                }
            }
        }
        if lastPaneProgram == "Claude" {
            claudeLogWatcher?.poll()
        } else if lastPaneProgram == "Codex" {
            codexLogWatcher?.poll()
        } else if lastPaneProgram == "Gemini" {
            geminiLogWatcher?.poll()
        }
    }

    private func setPlanArtifact(_ artifact: TerminalPlanArtifact?) {
        guard artifact != currentPlanArtifact else { return }
        currentPlanArtifact = artifact
        bridge.sendPlanState(artifact)
    }

    private func sendCurrentPlanState() {
        bridge.sendPlanState(currentPlanArtifact)
    }

    private func currentPaneProgramName(sessionName: String, tmuxPath: String) -> String {
        let currentRaw = runProcessCaptureOutput(
            executable: tmuxPath,
            arguments: ["display-message", "-p", "-t", sessionName, "#{pane_current_command}"]
        )
        let startCommandRaw = runProcessCaptureOutput(
            executable: tmuxPath,
            arguments: ["display-message", "-p", "-t", sessionName, "#{pane_start_command}"]
        )

        if let special = specialProgramDisplayName(
            currentCommand: currentRaw,
            startCommand: startCommandRaw,
            foregroundCommandLine: nil,
            panePidCommandLine: nil,
            ttyCommandLines: []
        ) {
            return special
        }

        if let current = normalizedCommandName(currentRaw),
           !current.isEmpty,
           !isShellCommand(current),
           !isGenericWrapperCommand(current),
           !isVersionLikeLabel(current) {
            return current
        }

        if let paneTTY = runProcessCaptureOutput(
            executable: tmuxPath,
            arguments: ["display-message", "-p", "-t", sessionName, "#{pane_tty}"]
        ) {
            let tty = URL(fileURLWithPath: paneTTY).lastPathComponent
            let ttyCommandLines = ttyProcessCommandLines(tty: tty)
            let foregroundLine = foregroundCommandLine(onTTY: tty)
            // Check the foreground process alone first — it takes priority over background
            // TTY processes. This prevents a lingering background process (e.g. a previous
            // Gemini node process) from shadowing the actual foreground program (e.g. Claude).
            if let special = specialProgramDisplayName(
                currentCommand: currentRaw,
                startCommand: startCommandRaw,
                foregroundCommandLine: foregroundLine,
                panePidCommandLine: nil,
                ttyCommandLines: []
            ) {
                return special
            }
            // Fall back to all TTY processes if foreground alone didn't match.
            if let special = specialProgramDisplayName(
                currentCommand: currentRaw,
                startCommand: startCommandRaw,
                foregroundCommandLine: foregroundLine,
                panePidCommandLine: nil,
                ttyCommandLines: ttyCommandLines
            ) {
                return special
            }
            if let foreground = foregroundCommand(onTTY: tty), !isShellCommand(foreground) {
                return foreground
            }
        }

        if let panePidRaw = runProcessCaptureOutput(
            executable: tmuxPath,
            arguments: ["display-message", "-p", "-t", sessionName, "#{pane_pid}"]
        ),
           let panePid = Int32(panePidRaw),
           let comm = normalizedCommandName(
            runProcessCaptureOutput(executable: "/bin/ps", arguments: ["-o", "comm=", "-p", String(panePid)])
           ) {
            let commandLine = runProcessCaptureOutput(
                executable: "/bin/ps",
                arguments: ["-o", "command=", "-p", String(panePid)]
            )
            if let special = specialProgramDisplayName(
                currentCommand: currentRaw,
                startCommand: startCommandRaw,
                foregroundCommandLine: nil,
                panePidCommandLine: commandLine,
                ttyCommandLines: []
            ) {
                return special
            }
            let executable = URL(fileURLWithPath: comm).lastPathComponent
            if !executable.isEmpty {
                return executable
            }
        }

        return normalizedCommandName(
            runProcessCaptureOutput(
                executable: tmuxPath,
                arguments: ["display-message", "-p", "-t", sessionName, "#{pane_current_command}"]
            )
        ) ?? ""
    }

    private func specialProgramDisplayName(
        currentCommand: String?,
        startCommand: String?,
        foregroundCommandLine: String?,
        panePidCommandLine: String?,
        ttyCommandLines: [String]
    ) -> String? {
        let values = [currentCommand, startCommand, foregroundCommandLine, panePidCommandLine]
            .compactMap { $0?.lowercased() }
        let ttyValues = ttyCommandLines.map { $0.lowercased() }
        let allValues = values + ttyValues

        if allValues.contains(where: { $0.contains("codex") || $0.contains("@openai/codex") || $0.contains("openai codex") }) {
            return "Codex"
        }

        // Claude is checked before Gemini because "gemini" can appear as a substring in
        // claude CLI arguments (e.g. --resume gemini-cli-notification-parity), causing a
        // false-positive Gemini match. "claude" is a stronger signal and should win.
        if allValues.contains(where: { $0.contains("claude") || $0.contains("anthropic") || $0.contains("claude-code") }) {
            return "Claude"
        }

        if allValues.contains(where: { $0.contains("gemini") || $0.contains("@google/gemini-cli") || $0.contains("gemini-cli") || $0.contains("google gemini") }) {
            return "Gemini"
        }

        if isVersionLikeLabel(currentCommand),
           ttyValues.contains(where: { $0.contains("claude") || $0.contains("anthropic") }) {
            return "Claude"
        }

        return nil
    }

    private func ttyProcessCommandLines(tty: String) -> [String] {
        guard let output = runProcessCaptureOutput(
            executable: "/bin/ps",
            arguments: ["-t", tty, "-o", "command="]
        ) else {
            return []
        }
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func isVersionLikeLabel(_ value: String?) -> Bool {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        let pattern = #"^\d+\.\d+\.\d+([.-][A-Za-z0-9]+)?$"#
        return raw.range(of: pattern, options: .regularExpression) != nil
    }

    private func foregroundCommandLine(onTTY tty: String) -> String? {
        guard let output = runProcessCaptureOutput(
            executable: "/bin/ps",
            arguments: ["-t", tty, "-o", "stat=,command="]
        ) else {
            return nil
        }

        for line in output.split(separator: "\n") {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.contains("+") else { continue }
            let components = raw.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard components.count == 2 else { continue }
            let commandLine = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !commandLine.isEmpty {
                return commandLine
            }
        }
        return nil
    }

    private func foregroundCommand(onTTY tty: String) -> String? {
        guard let output = runProcessCaptureOutput(
            executable: "/bin/ps",
            arguments: ["-t", tty, "-o", "stat=,comm="]
        ) else {
            return nil
        }

        for line in output.split(separator: "\n") {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.contains("+") else { continue }
            let components = raw.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard components.count == 2 else { continue }
            let command = normalizedCommandName(String(components[1]))
            if let command, !command.isEmpty {
                return command
            }
        }
        return nil
    }

    private func normalizedCommandName(_ value: String?) -> String? {
        guard var command = value?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return nil
        }
        command = URL(fileURLWithPath: command).lastPathComponent
        if command.hasPrefix("-") {
            command.removeFirst()
        }
        return command.isEmpty ? nil : command
    }

    private func isShellCommand(_ command: String) -> Bool {
        switch command {
        case "sh", "bash", "zsh", "fish", "ksh", "tcsh", "dash":
            return true
        default:
            return false
        }
    }

    private func isGenericWrapperCommand(_ command: String) -> Bool {
        switch command {
        case "node", "bun", "deno", "python", "python3", "ruby", "java", "perl":
            return true
        default:
            return false
        }
    }

    private func runProcessCaptureOutput(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        } catch {
            logger.error("Process failed (\(arguments.joined(separator: " "))): \(error.localizedDescription)")
            return nil
        }
    }

    private func sendPeerRetiredIfNeeded(reason: String) {
        guard !retirementSent else { return }
        retirementSent = true
        bridge.sendPeerRetiredSync(reason: reason)
    }
}

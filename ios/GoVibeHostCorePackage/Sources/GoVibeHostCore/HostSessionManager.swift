@preconcurrency import ApplicationServices
import Foundation
import Observation

protocol ManagedHostRuntime: AnyObject {
    func start() throws
    func stop()
    func remove()
}

extension ManagedHostRuntime {
    func remove() { stop() }
}

@MainActor
@Observable
public final class HostSessionManager {
    private enum Keys {
        static let settings = "govibe.host.settings"
        static let sessions = "govibe.host.sessions"
    }

    public private(set) var settings: HostSettings
    public private(set) var sessions: [HostedSessionDescriptor]
    public private(set) var bootedSimulators: [BootedSimulatorDevice] = []
    public private(set) var permissionState: HostPermissionState
    public var selectedSessionID: String?
    public private(set) var isTmuxInstalling: Bool = false
    public private(set) var isClaudeHookInstalling: Bool = false
    public private(set) var isGeminiHookInstalling: Bool = false

    private let defaults: UserDefaults
    private var logsBySessionID: [String: [HostLogEntry]] = [:]
    private var runtimes: [String: ManagedHostRuntime] = [:]
    private var controlChannel: HostControlChannel?
    private var didAutoStartPersistedSessions = false
    private var currentUserID: String?
    private let sessionSync = HostSessionSync()

    public init(defaults: UserDefaults = .standard, bundle: Bundle = .main, userID: String? = nil) {
        self.defaults = defaults
        self.currentUserID = userID
        let loadedState = Self.loadState(defaults: defaults, bundle: bundle, userID: userID)
        self.settings = loadedState.settings
        self.sessions = loadedState.sessions
        self.permissionState = HostPermissionState(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            tmuxInstalled: Self.detectTmux(),
            claudeHookInstalled: Self.detectClaudeHook(),
            geminiHookInstalled: Self.detectGeminiHook()
        )
        self.selectedSessionID = sessions.first?.sessionId
        refreshPermissions()
        // Persist corrected states so UserDefaults stays consistent.
        if let data = try? JSONEncoder().encode(self.sessions) {
            defaults.set(data, forKey: Self.scopedKey(Keys.sessions, userID: userID))
        }
    }

    public func syncAuthScope(userID: String?) {
        guard currentUserID != userID else { return }

        stopAllSessions()
        logsBySessionID.removeAll()
        currentUserID = userID

        let loadedState = Self.loadState(defaults: defaults, bundle: .main, userID: userID)
        settings = loadedState.settings
        sessions = loadedState.sessions
        selectedSessionID = sessions.first?.sessionId
        didAutoStartPersistedSessions = false
        refreshPermissions()

        let hostId = settings.hostId
        let uid = userID ?? ""
        let snapshot = sessions
        Task.detached { [sessionSync] in
            await sessionSync.configure(hostId: hostId, ownerUid: uid)
            await sessionSync.syncAll(snapshot)
        }
    }

    public func updateFromConfig() {
        let newRelay = HostConfig.shared.relayWebSocketBase ?? ""
        if settings.relayBase != newRelay {
            settings.relayBase = newRelay
            persistSettings()
            startControlChannel()
        }
        autoStartPersistedSessionsIfNeeded()
    }

    public func refreshEnvironment() {
        refreshPermissions()
        bootedSimulators = SimulatorBridge.bootedSimulators()
    }

    public func refreshPermissions() {
        permissionState = HostPermissionState(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            tmuxInstalled: Self.detectTmux(),
            claudeHookInstalled: Self.detectClaudeHook(),
            geminiHookInstalled: Self.detectGeminiHook()
        )
    }

    private static func detectTmux() -> Bool {
        let candidates = [
            "/opt/homebrew/bin/tmux",  // Homebrew Apple Silicon
            "/usr/local/bin/tmux",     // Homebrew Intel
            "/opt/local/bin/tmux",     // MacPorts
            "/usr/bin/tmux",
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    public func installTmux() async {
        isTmuxInstalling = true
        defer { isTmuxInstalling = false }

        let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let brewPath = brewCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return
        }

        let process = Process()
        process.executableURL = URL(filePath: brewPath)
        process.arguments = ["install", "tmux"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        refreshPermissions()
    }

    /// Returns true if ~/.claude/settings.json has both GoVibe hooks:
    /// - `Notification`/`permission_prompt` → govibe-permission-pending
    /// - `Stop` → govibe-turn-complete-pending
    private static func detectClaudeHook() -> Bool {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any] else {
            return false
        }

        var hasPermission = false
        if let notificationHooks = hooks["Notification"] as? [[String: Any]] {
            outer: for entry in notificationHooks {
                guard (entry["matcher"] as? String) == "permission_prompt",
                      let innerHooks = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in innerHooks {
                    if let cmd = hook["command"] as? String, cmd.contains("govibe-") && cmd.contains("permission-pending") {
                        hasPermission = true
                        break outer
                    }
                }
            }
        }
        guard hasPermission else { return false }

        var hasStop = false
        if let stopHooks = hooks["Stop"] as? [[String: Any]] {
            outer: for entry in stopHooks {
                guard let innerHooks = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in innerHooks {
                    if let cmd = hook["command"] as? String, cmd.contains("govibe-") && cmd.contains("turn-complete-pending") {
                        hasStop = true
                        break outer
                    }
                }
            }
        }
        return hasStop
    }

    public func installClaudeHook() async {
        isClaudeHookInstalling = true
        defer { isClaudeHookInstalling = false }

        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        var root: [String: Any] = (
            (try? Data(contentsOf: settingsURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        ) ?? [:]

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var notificationHooks = hooks["Notification"] as? [[String: Any]] ?? []

        let permissionEntry: [String: Any] = [
            "matcher": "permission_prompt",
            "hooks": [
                ["type": "command", "command": "[ -n \"$TMUX\" ] && S=$(tmux display-message -p '#{session_name}' 2>/dev/null) && touch ~/.claude/govibe-${S}-permission-pending"]
            ]
        ]
        notificationHooks.append(permissionEntry)
        hooks["Notification"] = notificationHooks

        // Stop hook — fires when Claude finishes a turn (replaces end_turn JSONL detection).
        var stopHooks = hooks["Stop"] as? [[String: Any]] ?? []
        let stopEntry: [String: Any] = [
            "hooks": [
                ["type": "command", "command": "[ -n \"$TMUX\" ] && S=$(tmux display-message -p '#{session_name}' 2>/dev/null) && touch ~/.claude/govibe-${S}-turn-complete-pending"]
            ]
        ]
        stopHooks.append(stopEntry)
        hooks["Stop"] = stopHooks

        root["hooks"] = hooks

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }

        // Ensure the ~/.claude directory exists.
        let claudeDir = settingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try? data.write(to: settingsURL, options: .atomic)
        refreshPermissions()
    }

    /// Returns true if ~/.gemini/settings.json has both the AfterAgent and
    /// ToolPermission Notification hooks that write GoVibe's sentinel files.
    private static func detectGeminiHook() -> Bool {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any] else {
            return false
        }

        // Check AfterAgent hook for turn-complete sentinel.
        // Each entry must use the nested { hooks: [...] } format required by Gemini CLI.
        var hasAfterAgent = false
        if let afterAgentEntries = hooks["AfterAgent"] as? [[String: Any]] {
            outer: for entry in afterAgentEntries {
                guard let innerHooks = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in innerHooks {
                    if let cmd = hook["command"] as? String,
                       cmd.contains("govibe-") && cmd.contains("turn-complete-pending") {
                        hasAfterAgent = true
                        break outer
                    }
                }
            }
        }
        guard hasAfterAgent else { return false }

        // Check Notification / ToolPermission hook for permission sentinel.
        guard let notificationHooks = hooks["Notification"] as? [[String: Any]] else {
            return false
        }
        for entry in notificationHooks {
            guard (entry["matcher"] as? String) == "ToolPermission",
                  let innerHooks = entry["hooks"] as? [[String: Any]] else { continue }
            for hook in innerHooks {
                if let cmd = hook["command"] as? String,
                   cmd.contains("govibe-") && cmd.contains("permission-pending") {
                    return true
                }
            }
        }
        return false
    }

    public func installGeminiHook() async {
        isGeminiHookInstalling = true
        defer { isGeminiHookInstalling = false }

        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/settings.json")

        var root: [String: Any] = (
            (try? Data(contentsOf: settingsURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        ) ?? [:]

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // AfterAgent hook — fires when Gemini finishes a turn.
        // Gemini CLI requires the nested { hooks: [...] } wrapper on every definition entry.
        var afterAgentHooks = hooks["AfterAgent"] as? [[String: Any]] ?? []
        let afterAgentEntry: [String: Any] = [
            "hooks": [
                ["type": "command", "command": "[ -n \"$TMUX\" ] && S=$(tmux display-message -p '#{session_name}' 2>/dev/null) && touch ~/.gemini/govibe-${S}-turn-complete-pending"]
            ]
        ]
        afterAgentHooks.append(afterAgentEntry)
        hooks["AfterAgent"] = afterAgentHooks

        // Notification / ToolPermission hook — fires when Gemini needs tool approval.
        var notificationHooks = hooks["Notification"] as? [[String: Any]] ?? []
        let notificationEntry: [String: Any] = [
            "matcher": "ToolPermission",
            "hooks": [
                ["type": "command", "command": "[ -n \"$TMUX\" ] && S=$(tmux display-message -p '#{session_name}' 2>/dev/null) && touch ~/.gemini/govibe-${S}-permission-pending"]
            ]
        ]
        notificationHooks.append(notificationEntry)
        hooks["Notification"] = notificationHooks

        root["hooks"] = hooks

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }

        let geminiDir = settingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        try? data.write(to: settingsURL, options: .atomic)
        refreshPermissions()
    }

    public func setBootedSimulators(_ simulators: [BootedSimulatorDevice]) {
        bootedSimulators = simulators
    }

    public func requestAccessibilityAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshPermissions()
    }

    public func requestScreenRecordingAccess() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
    }

    public func completeOnboarding(relayBase: String, defaultShellPath: String, preferredSimulatorUDID: String?) {
        settings.relayBase = relayBase.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.defaultShellPath = defaultShellPath
        settings.preferredSimulatorUDID = preferredSimulatorUDID
        settings.onboardingCompleted = !settings.relayBase.isEmpty
        persistSettings()
        refreshPermissions()
        autoStartPersistedSessionsIfNeeded()
    }

    public func restartSetup() {
        stopAllSessions()
        settings.onboardingCompleted = false
        persistSettings()
        refreshPermissions()
    }

    public func listSessions() -> [HostedSessionDescriptor] {
        sessions
    }

    // MARK: - Control Channel

    /// Starts the host control channel so iOS peers can create sessions remotely.
    /// Safe to call multiple times — restarts if already running.
    public func startControlChannel() {
        guard settings.onboardingCompleted, !settings.relayBase.isEmpty else { return }
        controlChannel?.stop()

        let logger = HostLogger(sessionId: "control") { [weak self] entry in
            Task { @MainActor in
                self?.logsBySessionID["control", default: []].append(entry)
            }
        }
        let channel = HostControlChannel(
            hostId: settings.hostId,
            relayBase: settings.relayBase,
            logger: logger
        )
        channel.onCreateSession = { [weak self, weak channel] sessionId, tmuxSession in
            Task { @MainActor in
                guard let self, let channel else { return }
                let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    channel.sendSessionError(sessionId: sessionId, error: "Invalid session ID")
                    return
                }
                if self.sessions.contains(where: { $0.sessionId == trimmed }) {
                    channel.sendSessionError(sessionId: trimmed, error: "Session '\(trimmed)' already exists")
                    return
                }
                let effectiveTmux = (tmuxSession ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let config = TerminalSessionConfig(
                    sessionId: trimmed,
                    shellPath: self.settings.defaultShellPath,
                    tmuxSessionName: effectiveTmux.isEmpty ? trimmed : effectiveTmux
                )
                self.createTerminalSession(config: config)
                channel.sendSessionCreated(sessionId: trimmed)
            }
        }
        channel.onDeleteSession = { [weak self, weak channel] sessionId, killTmux in
            Task { @MainActor in
                guard let self, let channel else { return }
                let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                if self.sessions.contains(where: { $0.sessionId == trimmed }) {
                    if killTmux {
                        self.removeSession(id: trimmed)
                    } else {
                        self.detachSession(id: trimmed)
                    }
                    channel.sendSessionDeleted(sessionId: trimmed)
                } else {
                    channel.sendSessionError(sessionId: trimmed, error: "Session not found")
                }
            }
        }
        channel.onListTmuxSessions = { [weak channel] in
            guard let channel else { return }
            Task { @MainActor [weak channel] in
                guard let channel else { return }
                let sessions = await Task.detached(priority: .userInitiated) {
                    PtySession.listTmuxSessions()
                }.value
                channel.sendTmuxSessionsList(sessions)
            }
        }
        channel.start()
        controlChannel = channel
    }

    public func stopControlChannel() {
        controlChannel?.stop()
        controlChannel = nil
    }

    public func createTerminalSession(config: TerminalSessionConfig) {
        let sessionID = config.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return }
        guard !sessions.contains(where: { $0.sessionId == sessionID }) else { return }
        let descriptor = HostedSessionDescriptor(
            hostId: settings.hostId,
            sessionId: sessionID,
            kind: .terminal,
            displayName: config.tmuxSessionName,
            state: .stopped,
            configuration: .terminal(config)
        )
        sessions.append(descriptor)
        selectedSessionID = descriptor.sessionId
        persistSessions()
        startSession(id: descriptor.sessionId)
        Task.detached { [sessionSync] in await sessionSync.upsert(descriptor) }
    }

    public func createSimulatorSession(config: SimulatorSessionConfig) {
        let sessionID = config.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return }
        guard !sessions.contains(where: { $0.sessionId == sessionID }) else { return }
        let descriptor = HostedSessionDescriptor(
            hostId: settings.hostId,
            sessionId: sessionID,
            kind: .simulator,
            displayName: config.preferredUDID ?? "Simulator",
            state: .stopped,
            configuration: .simulator(config)
        )
        sessions.append(descriptor)
        selectedSessionID = descriptor.sessionId
        persistSessions()
        startSession(id: descriptor.sessionId)
        Task.detached { [sessionSync] in await sessionSync.upsert(descriptor) }
    }


    public func createAppWindowSession(config: AppWindowSessionConfig) {
        let sessionID = config.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else { return }
        guard !sessions.contains(where: { $0.sessionId == sessionID }) else { return }
        let descriptor = HostedSessionDescriptor(
            hostId: settings.hostId,
            sessionId: sessionID,
            kind: .appWindow,
            displayName: config.windowTitle,
            state: .stopped,
            configuration: .appWindow(config)
        )
        sessions.append(descriptor)
        selectedSessionID = descriptor.sessionId
        persistSessions()
        startSession(id: descriptor.sessionId)
        Task.detached { [sessionSync] in await sessionSync.upsert(descriptor) }
    }

    public func startSession(id: String) {
        guard runtimes[id] == nil,
              let descriptor = sessions.first(where: { $0.sessionId == id }) else { return }

        let logger = HostLogger(sessionId: id) { [weak self] entry in
            Task { @MainActor in
                self?.logsBySessionID[id, default: []].append(entry)
            }
        }

        let runtime: ManagedHostRuntime
        switch descriptor.configuration {
        case .terminal(let config):
            runtime = TerminalHostSession(
                hostId: settings.hostId,
                config: config,
                relayBase: settings.relayBase,
                logger: logger
            ) { [weak self] event in
                Task { @MainActor in
                    self?.handleRuntimeEvent(event, sessionID: id)
                }
            }
        case .simulator(let config):
            runtime = SimulatorHostSession(
                hostId: settings.hostId,
                config: config,
                relayBase: settings.relayBase,
                logger: logger
            ) { [weak self] event in
                Task { @MainActor in
                    self?.handleRuntimeEvent(event, sessionID: id)
                }
            }
        case .appWindow(let config):
            runtime = AppWindowHostSession(
                hostId: settings.hostId,
                config: config,
                relayBase: settings.relayBase,
                logger: logger
            ) { [weak self] event in
                Task { @MainActor in
                    self?.handleRuntimeEvent(event, sessionID: id)
                }
            }
        }

        runtimes[id] = runtime
        updateSession(id: id) { descriptor in
            descriptor.state = .starting
            descriptor.lastError = nil
        }
        do {
            try runtime.start()
        } catch {
            runtimes[id] = nil
            updateSession(id: id) { descriptor in
                descriptor.state = .error
                descriptor.lastError = error.localizedDescription
            }
            logsBySessionID[id, default: []].append(
                HostLogEntry(sessionId: id, level: .error, message: error.localizedDescription)
            )
        }
    }

    public func stopSession(id: String) {
        runtimes[id]?.stop()
        runtimes[id] = nil
        updateSession(id: id) { descriptor in
            descriptor.state = .stopped
        }
    }

    public func stopAllSessions() {
        didAutoStartPersistedSessions = false
        for id in runtimes.keys {
            runtimes[id]?.stop()
        }
        runtimes.removeAll()
        for index in sessions.indices {
            sessions[index].state = .stopped
        }
        stopControlChannel()
        persistSessions()
        Task.detached { [sessionSync] in await sessionSync.removeAll() }
    }

    public func removeSession(id: String) {
        runtimes[id]?.remove()
        runtimes[id] = nil
        updateSession(id: id) { descriptor in
            descriptor.state = .stopped
        }
        sessions.removeAll { $0.sessionId == id }
        logsBySessionID[id] = nil
        if selectedSessionID == id {
            selectedSessionID = sessions.first?.sessionId
        }
        persistSessions()
        Task.detached { [sessionSync] in await sessionSync.remove(sessionId: id) }
    }

    /// Removes the session from GoVibe tracking without killing the underlying tmux session.
    public func detachSession(id: String) {
        runtimes[id]?.stop()
        runtimes[id] = nil
        updateSession(id: id) { descriptor in
            descriptor.state = .stopped
        }
        sessions.removeAll { $0.sessionId == id }
        logsBySessionID[id] = nil
        if selectedSessionID == id {
            selectedSessionID = sessions.first?.sessionId
        }
        persistSessions()
        Task.detached { [sessionSync] in await sessionSync.remove(sessionId: id) }
    }

    public func sessionLogs(id: String) -> [HostLogEntry] {
        logsBySessionID[id] ?? []
    }

    private func autoStartPersistedSessionsIfNeeded() {
        guard !didAutoStartPersistedSessions,
              settings.onboardingCompleted,
              !settings.relayBase.isEmpty else { return }

        didAutoStartPersistedSessions = true
        startControlChannel()

        let snapshot = sessions
        Task.detached { [sessionSync] in
            await sessionSync.syncAll(snapshot)
        }

        for session in sessions where runtimes[session.sessionId] == nil {
            startSession(id: session.sessionId)
        }
    }

    private func handleRuntimeEvent(_ event: HostSessionRuntimeEvent, sessionID: String) {
        switch event {
        case .stateChanged(let state, let lastPeerActivityAt, let message):
            updateSession(id: sessionID) { descriptor in
                descriptor.state = state
                descriptor.lastPeerActivityAt = lastPeerActivityAt
                descriptor.lastError = message
            }
            if state == .stopped || state == .error {
                runtimes[sessionID] = nil
            }
        }
    }

    private func updateSession(id: String, mutate: (inout HostedSessionDescriptor) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.sessionId == id }) else { return }
        mutate(&sessions[index])
        persistSessions()
        let updated = sessions[index]
        Task.detached { [sessionSync] in await sessionSync.upsert(updated) }
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.scopedKey(Keys.settings, userID: currentUserID))
        }
    }

    private func persistSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: Self.scopedKey(Keys.sessions, userID: currentUserID))
        }
    }

    private static func scopedKey(_ base: String, userID: String?) -> String {
        guard let userID, !userID.isEmpty else { return "\(base).guest" }
        return "\(base).\(userID)"
    }

    private static func loadState(defaults: UserDefaults, bundle: Bundle, userID: String?) -> (settings: HostSettings, sessions: [HostedSessionDescriptor]) {
        migrateLegacyStateIfNeeded(defaults: defaults, userID: userID)

        let persistedSettings = defaults.data(forKey: scopedKey(Keys.settings, userID: userID))
            .flatMap { try? JSONDecoder().decode(HostSettings.self, from: $0) }
        let configRelay = HostConfig.shared.relayWebSocketBase ?? ""
        var defaultsSettings = HostRuntimeDefaults.makeSettings(userID: userID, bundle: bundle)
        // If no persisted settings for this user but a relay is already configured
        // (e.g. switching from Apple to Google sign-in), auto-onboard so the host
        // registers as discoverable immediately without requiring the setup flow again.
        if persistedSettings == nil, !configRelay.isEmpty {
            defaultsSettings.onboardingCompleted = true
        }
        let resolvedSettings = persistedSettings ?? defaultsSettings
        let effectiveRelay: String
        if resolvedSettings.onboardingCompleted || configRelay.isEmpty {
            effectiveRelay = resolvedSettings.relayBase
        } else {
            effectiveRelay = configRelay
        }

        let settings = HostSettings(
            hostId: HostMachineIdentity.resolveHostID(userID: userID),
            relayBase: effectiveRelay,
            defaultShellPath: resolvedSettings.defaultShellPath,
            preferredSimulatorUDID: resolvedSettings.preferredSimulatorUDID,
            onboardingCompleted: resolvedSettings.onboardingCompleted
        )

        let loadedSessions = defaults.data(forKey: scopedKey(Keys.sessions, userID: userID))
            .flatMap { try? JSONDecoder().decode([HostedSessionDescriptor].self, from: $0) } ?? []
        let sessions = loadedSessions.map { descriptor in
                var d = descriptor
                switch d.state {
                case .stopped, .error:
                    break
                default:
                    d.state = .stopped
                }
                d.hostId = settings.hostId
                return d
            }

        return (settings, sessions)
    }

    private static func migrateLegacyStateIfNeeded(defaults: UserDefaults, userID: String?) {
        guard let userID, !userID.isEmpty else { return }

        let scopedSettingsKey = scopedKey(Keys.settings, userID: userID)
        let scopedSessionsKey = scopedKey(Keys.sessions, userID: userID)
        let hasScopedSettings = defaults.data(forKey: scopedSettingsKey) != nil
        let hasScopedSessions = defaults.data(forKey: scopedSessionsKey) != nil
        if hasScopedSettings || hasScopedSessions {
            return
        }

        if let legacySettings = defaults.data(forKey: Keys.settings) {
            defaults.set(legacySettings, forKey: scopedSettingsKey)
            defaults.removeObject(forKey: Keys.settings)
        }

        if let legacySessions = defaults.data(forKey: Keys.sessions) {
            defaults.set(legacySessions, forKey: scopedSessionsKey)
            defaults.removeObject(forKey: Keys.sessions)
        }
    }
}

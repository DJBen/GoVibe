@preconcurrency import ApplicationServices
import Foundation
import Observation

protocol ManagedHostRuntime: AnyObject {
    func start() throws
    func stop()
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

    private let defaults: UserDefaults
    private var logsBySessionID: [String: [HostLogEntry]] = [:]
    private var runtimes: [String: ManagedHostRuntime] = [:]

    public init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        let persistedSettings = defaults.data(forKey: Keys.settings)
            .flatMap { try? JSONDecoder().decode(HostSettings.self, from: $0) }
        let defaultsSettings = HostRuntimeDefaults.makeSettings(bundle: bundle)
        let resolvedSettings = persistedSettings ?? defaultsSettings
        self.settings = HostSettings(
            hostId: resolvedSettings.hostId,
            relayBase: resolvedSettings.relayBase,
            defaultShellPath: resolvedSettings.defaultShellPath,
            preferredSimulatorUDID: resolvedSettings.preferredSimulatorUDID,
            onboardingCompleted: resolvedSettings.onboardingCompleted
        )
        let loadedSessions = defaults.data(forKey: Keys.sessions)
            .flatMap { try? JSONDecoder().decode([HostedSessionDescriptor].self, from: $0) } ?? []
        // Reset any active state — runtimes don't survive across launches.
        self.sessions = loadedSessions.map { descriptor in
            var d = descriptor
            switch d.state {
            case .stopped, .error:
                break
            default:
                d.state = .stopped
            }
            return d
        }
        self.permissionState = HostPermissionState(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess()
        )
        self.selectedSessionID = sessions.first?.sessionId
        refreshPermissions()
        // Persist corrected states so UserDefaults stays consistent.
        if let data = try? JSONEncoder().encode(self.sessions) {
            defaults.set(data, forKey: Keys.sessions)
        }
    }

    public func refreshEnvironment() {
        refreshPermissions()
        bootedSimulators = SimulatorBridge.bootedSimulators()
    }

    public func refreshPermissions() {
        permissionState = HostPermissionState(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess()
        )
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
    }

    public func listSessions() -> [HostedSessionDescriptor] {
        sessions
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

    public func removeSession(id: String) {
        stopSession(id: id)
        sessions.removeAll { $0.sessionId == id }
        logsBySessionID[id] = nil
        if selectedSessionID == id {
            selectedSessionID = sessions.first?.sessionId
        }
        persistSessions()
    }

    public func sessionLogs(id: String) -> [HostLogEntry] {
        logsBySessionID[id] ?? []
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
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Keys.settings)
        }
    }

    private func persistSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: Keys.sessions)
        }
    }
}

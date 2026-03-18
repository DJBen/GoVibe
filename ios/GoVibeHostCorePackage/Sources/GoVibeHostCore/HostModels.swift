import Foundation
import CoreGraphics

public enum HostedSessionKind: String, Codable, CaseIterable, Sendable {
    case terminal
    case simulator
    case appWindow
}

public enum HostedSessionState: String, Codable, CaseIterable, Sendable {
    case stopped
    case starting
    case running
    case waitingForPeer
    case stale
    case error

    public var displayLabel: String {
        rawValue
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .localizedCapitalized
    }
}

public struct TerminalSessionConfig: Codable, Hashable, Sendable {
    public var sessionId: String
    public var shellPath: String
    public var tmuxSessionName: String

    public init(sessionId: String, shellPath: String, tmuxSessionName: String) {
        self.sessionId = sessionId
        self.shellPath = shellPath
        self.tmuxSessionName = tmuxSessionName
    }
}

public struct SimulatorSessionConfig: Codable, Hashable, Sendable {
    public var sessionId: String
    public var preferredUDID: String?

    public init(sessionId: String, preferredUDID: String?) {
        self.sessionId = sessionId
        self.preferredUDID = preferredUDID
    }
}

public struct AppWindowSessionConfig: Codable, Hashable, Sendable {
    public var sessionId: String
    public var windowTitle: String
    public var bundleIdentifier: String?

    public init(sessionId: String, windowTitle: String, bundleIdentifier: String?) {
        self.sessionId = sessionId
        self.windowTitle = windowTitle
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct AvailableWindow: Identifiable, Sendable {
    public var id: CGWindowID
    public var title: String
    public var appName: String
    public var bundleIdentifier: String?

    public init(id: CGWindowID, title: String, appName: String, bundleIdentifier: String?) {
        self.id = id
        self.title = title
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }
}

public enum HostedSessionConfiguration: Codable, Hashable, Sendable {
    case terminal(TerminalSessionConfig)
    case simulator(SimulatorSessionConfig)
    case appWindow(AppWindowSessionConfig)

    private enum CodingKeys: String, CodingKey {
        case type
        case terminal
        case simulator
        case appWindow
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(HostedSessionKind.self, forKey: .type)
        switch type {
        case .terminal:
            self = .terminal(try container.decode(TerminalSessionConfig.self, forKey: .terminal))
        case .simulator:
            self = .simulator(try container.decode(SimulatorSessionConfig.self, forKey: .simulator))
        case .appWindow:
            self = .appWindow(try container.decode(AppWindowSessionConfig.self, forKey: .appWindow))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let config):
            try container.encode(HostedSessionKind.terminal, forKey: .type)
            try container.encode(config, forKey: .terminal)
        case .simulator(let config):
            try container.encode(HostedSessionKind.simulator, forKey: .type)
            try container.encode(config, forKey: .simulator)
        case .appWindow(let config):
            try container.encode(HostedSessionKind.appWindow, forKey: .type)
            try container.encode(config, forKey: .appWindow)
        }
    }
}

public struct HostedSessionDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var id: String { sessionId }
    public var hostId: String
    public var sessionId: String
    public var kind: HostedSessionKind
    public var displayName: String
    public var state: HostedSessionState
    public var createdAt: Date
    public var lastPeerActivityAt: Date?
    public var lastError: String?
    public var configuration: HostedSessionConfiguration

    public init(
        hostId: String,
        sessionId: String,
        kind: HostedSessionKind,
        displayName: String,
        state: HostedSessionState,
        createdAt: Date = .now,
        lastPeerActivityAt: Date? = nil,
        lastError: String? = nil,
        configuration: HostedSessionConfiguration
    ) {
        self.hostId = hostId
        self.sessionId = sessionId
        self.kind = kind
        self.displayName = displayName
        self.state = state
        self.createdAt = createdAt
        self.lastPeerActivityAt = lastPeerActivityAt
        self.lastError = lastError
        self.configuration = configuration
    }
}

public struct HostLogEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Level: String, Codable, Hashable, Sendable {
        case info
        case error
    }

    public var id: UUID
    public var sessionId: String
    public var timestamp: Date
    public var level: Level
    public var message: String

    public init(
        id: UUID = UUID(),
        sessionId: String,
        timestamp: Date = .now,
        level: Level,
        message: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

public struct BootedSimulatorDevice: Identifiable, Codable, Hashable, Sendable {
    public var id: String { udid }
    public var udid: String
    public var name: String

    public init(udid: String, name: String) {
        self.udid = udid
        self.name = name
    }
}

public struct HostPermissionState: Codable, Hashable, Sendable {
    public var accessibilityGranted: Bool
    public var screenRecordingGranted: Bool
    public var tmuxInstalled: Bool

    public init(accessibilityGranted: Bool, screenRecordingGranted: Bool, tmuxInstalled: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.tmuxInstalled = tmuxInstalled
    }
}

public struct HostSettings: Codable, Hashable, Sendable {
    public var hostId: String
    public var relayBase: String
    public var defaultShellPath: String
    public var preferredSimulatorUDID: String?
    public var onboardingCompleted: Bool

    public init(
        hostId: String,
        relayBase: String,
        defaultShellPath: String,
        preferredSimulatorUDID: String? = nil,
        onboardingCompleted: Bool = false
    ) {
        self.hostId = hostId
        self.relayBase = relayBase
        self.defaultShellPath = defaultShellPath
        self.preferredSimulatorUDID = preferredSimulatorUDID
        self.onboardingCompleted = onboardingCompleted
    }
}

import Foundation

struct SessionCreateResponse: Codable {
    struct Ice: Codable {
        struct Turn: Codable {
            let username: String
            let credential: String
            let ttl: Int
            let urls: [String]
        }

        let policy: String
        let relayRequired: Bool
        let turn: Turn
    }

    let sessionId: String
    let signalingPath: String
    let token: String
    let ice: Ice
}

struct SessionDiscoveryResponse: Codable {
    let roomIds: [String]
    let count: Int
}

struct HostDiscoveryResponse: Codable {
    let hosts: [DiscoveredHost]
    let count: Int
}

struct RelayTokenResponse: Codable {
    let token: String
    let room: String
    let role: String
    let expiresInSeconds: Int
}

struct DiscoveredHost: Codable, Hashable, Identifiable {
    let deviceId: String
    let displayName: String
    let capabilities: [String]
    let appVersion: String?
    let osVersion: String?
    let lastSeenAt: Date?
    let lastOnlineAt: Date?
    let isOnline: Bool

    var id: String { deviceId }
}

struct TerminalLine: Identifiable {
    let id = UUID()
    let text: String
}

enum SessionKind: String, Codable {
    case terminal
    case simulator
    case appWindow

    var iconName: String {
        switch self {
        case .terminal:  return "terminal"
        case .simulator: return "iphone"
        case .appWindow: return "macwindow"
        }
    }

    var displayName: String {
        switch self {
        case .terminal:  return "Terminal"
        case .simulator: return "Simulator"
        case .appWindow: return "App Window"
        }
    }
}

struct HostInfo: Identifiable, Codable, Hashable {
    var id: String       // stable host device ID from the authenticated macOS GoVibe Host app
    var name: String     // display name reported by the host
    var capabilities: [String]
    var isOnline: Bool?
    var lastSeenAt: Date?
    var lastOnlineAt: Date?

    init(
        id: String,
        name: String,
        capabilities: [String] = [],
        isOnline: Bool? = nil,
        lastSeenAt: Date? = nil,
        lastOnlineAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
        self.isOnline = isOnline
        self.lastSeenAt = lastSeenAt
        self.lastOnlineAt = lastOnlineAt
    }
}

struct SavedSession: Identifiable, Codable, Hashable {
    /// Relay room key — always `"\(hostId)-\(sessionId)"`.
    /// Scoped to the host so two hosts with identically-named sessions
    /// never share a relay room.
    var roomId: String
    /// The user-visible session name (e.g. "ios-dev").
    var sessionId: String
    var hostId: String
    var kind: SessionKind?
    var lastRelayStatus: String?
    var lastActiveAt: Date?      // set when user leaves session
    var lastConversationSummary: String?

    var id: String { roomId }

    init(sessionId: String, hostId: String) {
        self.sessionId = sessionId
        self.hostId = hostId
        self.roomId = "\(hostId)-\(sessionId)"
    }
}

struct SimInfo: Codable, Sendable, Equatable {
    let deviceName: String
    let udid: String
    let screenWidth: Int
    let screenHeight: Int
    let scale: Double
    let fps: Int
}


struct AppWindowInfo: Codable, Sendable, Equatable {
    let windowTitle: String
    let appName: String
    let screenWidth: Int
    let screenHeight: Int
    let scale: Double
    let fps: Int
}

struct TerminalPlanState: Identifiable, Equatable, Sendable {
    let assistant: String
    let turnId: String
    let title: String?
    let markdown: String
    let blockCount: Int

    var id: String { turnId }
}

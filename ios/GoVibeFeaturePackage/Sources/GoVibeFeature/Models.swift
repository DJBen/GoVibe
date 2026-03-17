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
    var id: String       // hostId UUID string from the macOS GoVibe Host app
    var name: String     // user-given display label

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct SavedSession: Identifiable, Codable, Hashable {
    var roomId: String
    var hostId: String
    var kind: SessionKind?
    var lastRelayStatus: String?
    var lastActiveAt: Date?      // set when user leaves session

    var id: String { roomId }

    init(roomId: String, hostId: String) {
        self.roomId = roomId
        self.hostId = hostId
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

struct TerminalPlanState: Equatable, Sendable {
    let assistant: String
    let turnId: String
    let title: String?
    let markdown: String
    let blockCount: Int
}

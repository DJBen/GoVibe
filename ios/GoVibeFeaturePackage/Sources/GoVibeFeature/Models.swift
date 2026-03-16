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

    var iconName: String {
        switch self {
        case .terminal:  return "terminal"
        case .simulator: return "iphone"
        }
    }

    var displayName: String {
        switch self {
        case .terminal:  return "Terminal"
        case .simulator: return "Simulator"
        }
    }
}

struct SavedSession: Identifiable, Codable, Hashable {
    var roomId: String
    var kind: SessionKind?
    var lastRelayStatus: String?
    var lastActiveAt: Date?      // set when user leaves session

    var id: String { roomId }

    init(roomId: String) {
        self.roomId = roomId
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

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

struct SavedSession: Identifiable, Codable, Hashable {
    var roomId: String

    var id: String { roomId }

    init(roomId: String) {
        self.roomId = roomId
    }
}

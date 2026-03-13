import Foundation

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

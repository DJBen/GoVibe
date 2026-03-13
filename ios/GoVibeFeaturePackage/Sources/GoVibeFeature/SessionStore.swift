import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    private let storageKey = "saved_sessions"

    var sessions: [SavedSession] = []
    var isLoading = false
    var errorMessage: String?

    init() {}

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        load()
    }

    func add(roomId: String) {
        let trimmedRoomId = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoomId.isEmpty else { return }
        if sessions.contains(where: { $0.roomId == trimmedRoomId }) { return }
        sessions.append(SavedSession(roomId: trimmedRoomId))
        save()
    }

    func delete(at offsets: IndexSet) {
        sessions.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(sessions)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            errorMessage = "Failed to persist session list."
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            sessions = []
            return
        }
        do {
            sessions = try JSONDecoder().decode([SavedSession].self, from: data)
        } catch {
            sessions = []
            errorMessage = "Failed to read local session list."
        }
    }
}

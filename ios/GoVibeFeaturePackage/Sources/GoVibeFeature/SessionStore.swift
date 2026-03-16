import FirebaseAuth
import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    private let baseKey = "saved_sessions"
    private let apiClient: GoVibeAPIClient

    var sessions: [SavedSession] = []
    var isLoading = false
    var errorMessage: String?
    var currentUserId: String?

    init(
        apiBaseURL: URL = AppRuntimeConfig.apiBaseURL
    ) {
        self.apiClient = GoVibeAPIClient(baseURL: apiBaseURL)
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            let user = try await ensureAuthenticated()
            currentUserId = user.uid
            load(for: user.uid)
        } catch {
            sessions = []
            errorMessage = error.localizedDescription
            return
        }
    }

    func add(roomId: String) {
        guard let userId = currentUserId else {
            errorMessage = APIError.notAuthenticated.localizedDescription
            return
        }

        let trimmedRoomId = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoomId.isEmpty else { return }

        if sessions.contains(where: { $0.roomId == trimmedRoomId }) { return }
        sessions.append(SavedSession(roomId: trimmedRoomId))
        save(for: userId)
    }

    func update(roomId: String, kind: SessionKind) {
        guard let index = sessions.firstIndex(where: { $0.roomId == roomId }) else { return }
        sessions[index].kind = kind
        guard let userId = currentUserId else { return }
        save(for: userId)
    }

    func update(roomId: String, relayStatus: String) {
        guard let index = sessions.firstIndex(where: { $0.roomId == roomId }) else { return }
        sessions[index].lastRelayStatus = relayStatus
        guard let userId = currentUserId else { return }
        save(for: userId)
    }

    func update(roomId: String, lastActiveAt: Date) {
        guard let index = sessions.firstIndex(where: { $0.roomId == roomId }) else { return }
        sessions[index].lastActiveAt = lastActiveAt
        guard let userId = currentUserId else { return }
        save(for: userId)
    }

    static func thumbnailURL(for roomId: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("govibe_thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = roomId.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).jpg")
    }

    func delete(at offsets: IndexSet) {
        guard let userId = currentUserId else {
            errorMessage = APIError.notAuthenticated.localizedDescription
            return
        }
        sessions.remove(atOffsets: offsets)
        save(for: userId)
    }

    private func storageKey(for userId: String) -> String {
        "\(baseKey)_\(userId)"
    }

    private func save(for userId: String) {
        do {
            let data = try JSONEncoder().encode(sessions)
            UserDefaults.standard.set(data, forKey: storageKey(for: userId))
        } catch {
            errorMessage = "Failed to persist session list."
        }
    }

    private func load(for userId: String) {
        guard let data = UserDefaults.standard.data(forKey: storageKey(for: userId)) else {
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

    private func ensureAuthenticated() async throws -> User {
        if let user = Auth.auth().currentUser {
            _ = try await user.getIDTokenResult(forcingRefresh: false)
            return user
        }

        do {
            let result = try await Auth.auth().signInAnonymously()
            _ = try await result.user.getIDTokenResult(forcingRefresh: true)
            return result.user
        } catch {
            throw APIError.notAuthenticated
        }
    }
}

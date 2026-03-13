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

        // Primary: relay presence (rooms with a Mac currently connected).
        // When this succeeds, treat relay rooms as source of truth and prune stale
        // locally persisted sessions that are no longer live.
        // Falls back gracefully — if the relay endpoint fails, locally saved sessions
        // are still shown and the error is surfaced to the user.
        do {
            let relayRooms = try await apiClient.fetchRelayRooms()
            replaceWithLiveRooms(relayRooms.roomIds)
            if let userId = currentUserId {
                save(for: userId)
            }
        } catch {
            errorMessage = error.localizedDescription
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

    func delete(at offsets: IndexSet) {
        guard let userId = currentUserId else {
            errorMessage = APIError.notAuthenticated.localizedDescription
            return
        }
        sessions.remove(atOffsets: offsets)
        save(for: userId)
    }

    private func replaceWithLiveRooms(_ roomIds: [String]) {
        sessions = roomIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { unique, roomId in
                if !unique.contains(roomId) {
                    unique.append(roomId)
                }
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map(SavedSession.init(roomId:))
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

import FirebaseAuth
import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    private let sessionsBaseKey = "saved_sessions"
    private let hostsBaseKey = "saved_hosts"
    private let apiClient: GoVibeAPIClient

    var sessions: [SavedSession] = []
    var hosts: [HostInfo] = []
    var isLoading = false
    var errorMessage: String?
    var currentUserId: String?

    private struct PersistedSavedSession: Decodable {
        let roomId: String
        let hostId: String?
        let kind: SessionKind?
        let lastRelayStatus: String?
        let lastActiveAt: Date?
    }

    init(
        apiBaseURL: URL = AppRuntimeConfig.apiBaseURL
    ) {
        self.apiClient = GoVibeAPIClient(baseURL: apiBaseURL)
    }

    func sessions(for hostId: String) -> [SavedSession] {
        sessions.filter { $0.hostId == hostId }
    }

    // MARK: - Lifecycle

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            let user = try await ensureAuthenticated()
            currentUserId = user.uid
            load(for: user.uid)
            loadHosts(for: user.uid)
        } catch {
            sessions = []
            hosts = []
            errorMessage = error.localizedDescription
            return
        }

        // Pull the latest session list from each known host.
        let hostsSnapshot = hosts
        for host in hostsSnapshot {
            await syncSessions(for: host)
        }
    }

    /// Queries `<hostId>-ctl` for the host's current sessions and merges any
    /// unknown sessions into the local store. Silently no-ops if the host is offline.
    func syncSessions(for host: HostInfo) async {
        let client = HostControlClient(relayWebSocketBase: AppRuntimeConfig.relayWebSocketBase)
        do {
            let remote = try await client.listSessions(hostId: host.id)
            var changed = false
            for summary in remote {
                if let index = sessions.firstIndex(where: { $0.roomId == summary.sessionId }) {
                    // Update kind if we didn't know it before
                    if sessions[index].kind == nil, let kind = summary.kind {
                        sessions[index].kind = kind
                        changed = true
                    }
                } else {
                    var s = SavedSession(roomId: summary.sessionId, hostId: host.id)
                    s.kind = summary.kind
                    sessions.append(s)
                    changed = true
                }
            }
            if changed, let userId = currentUserId {
                save(for: userId)
            }
        } catch {
            // Host is offline or unreachable — silently skip.
        }
    }

    // MARK: - Host Management

    func addHost(id: String, name: String) {
        guard let userId = currentUserId else {
            errorMessage = APIError.notAuthenticated.localizedDescription
            return
        }
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, !trimmedName.isEmpty else { return }
        guard !hosts.contains(where: { $0.id == trimmedId }) else { return }
        hosts.append(HostInfo(id: trimmedId, name: trimmedName))
        saveHosts(for: userId)
        save(for: userId)
    }

    func removeHost(id: String) {
        guard let userId = currentUserId else { return }
        hosts.removeAll { $0.id == id }
        sessions.removeAll { $0.hostId == id }
        saveHosts(for: userId)
        save(for: userId)
    }

    // MARK: - Session Management

    func add(roomId: String, hostId: String) {
        guard let userId = currentUserId else {
            errorMessage = APIError.notAuthenticated.localizedDescription
            return
        }
        let trimmedRoomId = roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoomId.isEmpty else { return }
        if sessions.contains(where: { $0.roomId == trimmedRoomId }) { return }
        sessions.append(SavedSession(roomId: trimmedRoomId, hostId: hostId))
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

    /// Deletes a session, attempting to remove it from the remote host first if applicable.
    func deleteSession(_ session: SavedSession) async {
        let client = HostControlClient(relayWebSocketBase: AppRuntimeConfig.relayWebSocketBase)
        do {
            try await client.deleteSession(hostId: session.hostId, sessionId: session.roomId)
        } catch {
            // If remote delete fails, we log it but proceed to delete locally
            // so the user isn't stuck with a zombie session in their UI.
            print("Remote delete failed for \(session.roomId): \(error.localizedDescription)")
        }
        delete(roomId: session.roomId)
    }

    func delete(roomId: String) {
        guard let userId = currentUserId else {
            errorMessage = APIError.notAuthenticated.localizedDescription
            return
        }
        sessions.removeAll { $0.roomId == roomId }
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

    // MARK: - Persistence

    private func storageKey(for userId: String) -> String {
        "\(sessionsBaseKey)_\(userId)"
    }

    private func hostsStorageKey(for userId: String) -> String {
        "\(hostsBaseKey)_\(userId)"
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
            let persisted = try JSONDecoder().decode([PersistedSavedSession].self, from: data)
            sessions = persisted.compactMap { session in
                guard let hostId = session.hostId, !hostId.isEmpty else { return nil }
                var saved = SavedSession(roomId: session.roomId, hostId: hostId)
                saved.kind = session.kind
                saved.lastRelayStatus = session.lastRelayStatus
                saved.lastActiveAt = session.lastActiveAt
                return saved
            }
        } catch {
            sessions = []
            errorMessage = "Failed to read local session list."
        }
    }

    private func saveHosts(for userId: String) {
        do {
            let data = try JSONEncoder().encode(hosts)
            UserDefaults.standard.set(data, forKey: hostsStorageKey(for: userId))
        } catch {
            errorMessage = "Failed to persist host list."
        }
    }

    private func loadHosts(for userId: String) {
        guard let data = UserDefaults.standard.data(forKey: hostsStorageKey(for: userId)) else {
            hosts = []
            return
        }
        do {
            hosts = try JSONDecoder().decode([HostInfo].self, from: data)
        } catch {
            hosts = []
        }
    }

    // MARK: - Auth

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

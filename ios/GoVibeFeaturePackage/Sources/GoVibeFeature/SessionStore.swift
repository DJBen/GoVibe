import FirebaseAuth
import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    private let sessionsBaseKey = "saved_sessions"
    private let legacyHostsBaseKey = "saved_hosts"
    private var apiClient: GoVibeAPIClient

    var sessions: [SavedSession] = []
    var hosts: [HostInfo] = []
    var isLoading = false
    var errorMessage: String?
    var currentUserId: String?

    // Persistent per-host control-channel listeners for real-time session updates.
    private var listenerTasks: [String: Task<Void, Never>] = [:]

    private struct PersistedSavedSession: Decodable {
        let roomId: String
        let sessionId: String?   // nil in data persisted before the host-scoped room fix
        let hostId: String?
        let kind: SessionKind?
        let lastRelayStatus: String?
        let lastActiveAt: Date?
    }

    init(
        apiBaseURL: URL? = AppRuntimeConfig.apiBaseURL
    ) {
        if let apiBaseURL {
            self.apiClient = GoVibeAPIClient(baseURL: apiBaseURL)
        } else {
            self.apiClient = GoVibeAPIClient(baseURL: URL(string: "https://unconfigured.local")!)
        }
    }
    
    func updateConfig() {
        if let url = AppConfig.shared.apiBaseURL {
            self.apiClient = GoVibeAPIClient(baseURL: url)
        }
    }
    
    func reset() {
        if let userId = currentUserId {
            clearPersistedState(for: userId)
        }
        sessions = []
        hosts = []
        errorMessage = nil
        stopAllListeners()
    }

    func sessions(for hostId: String) -> [SavedSession] {
        sessions.filter { $0.hostId == hostId }
    }

    // MARK: - Lifecycle

    func refresh() async {
        guard !isLoading else { return }
        guard AppConfig.shared.isValid else {
            errorMessage = "Configuration required."
            isLoading = false
            return
        }
        
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            let user = try await ensureAuthenticated()
            currentUserId = user.uid
            load(for: user.uid)
            try await refreshDiscoveredHosts()
        } catch {
            sessions = []
            hosts = []
            errorMessage = error.localizedDescription
            return
        }

        // Pull the latest session list from each known host in parallel so one stale
        // host cannot block the entire refresh spinner for multiple sequential timeouts.
        let hostsSnapshot = hosts
        await withTaskGroup(of: Void.self) { group in
            for host in hostsSnapshot {
                group.addTask { [weak self] in
                    await self?.syncSessions(for: host, timeout: .seconds(3))
                }
            }
        }
        reconcileListeners()
    }

    /// Queries `<hostId>-ctl` for the host's current sessions and merges into the local store.
    /// Silently no-ops if the host is offline.
    func syncSessions(for host: HostInfo, timeout: Duration = .seconds(10)) async {
        guard AppConfig.shared.isValid else { return }
        let relayBase = AppConfig.shared.relayWebSocketBase ?? ""
        guard !relayBase.isEmpty else { return }

        let client = HostControlClient(relayWebSocketBase: relayBase, apiBaseURL: AppRuntimeConfig.apiBaseURL)
        do {
            let remote = try await client.listSessions(hostId: host.id, timeout: timeout)
            applyRemoteSessions(remote, hostId: host.id)
        } catch {
            // Host is offline or unreachable — silently skip.
        }
    }

    /// Merges a remote session list into the local store, adding new sessions and
    /// removing ones that no longer exist on the host.
    private func applyRemoteSessions(_ remote: [HostSessionSummary], hostId: String) {
        var changed = false
        let remoteIds = Set(remote.map(\.sessionId))

        for summary in remote {
            if let index = sessions.firstIndex(where: { $0.sessionId == summary.sessionId && $0.hostId == hostId }) {
                if sessions[index].kind == nil, let kind = summary.kind {
                    sessions[index].kind = kind
                    changed = true
                }
            } else {
                var s = SavedSession(sessionId: summary.sessionId, hostId: hostId)
                s.kind = summary.kind
                sessions.append(s)
                changed = true
            }
        }

        let before = sessions.count
        sessions.removeAll { $0.hostId == hostId && !remoteIds.contains($0.sessionId) }
        if sessions.count != before { changed = true }

        if changed, let userId = currentUserId {
            save(for: userId)
        }
    }

    // MARK: - Persistent Listeners

    /// Starts or stops per-host listeners so each host has exactly one live WebSocket
    /// connection to its control channel. Unsolicited `sessions_list` messages are
    /// applied immediately without any polling delay.
    private func reconcileListeners() {
        guard AppConfig.shared.isValid,
              let relayBase = AppConfig.shared.relayWebSocketBase,
              !relayBase.isEmpty else {
            stopAllListeners()
            return
        }

        let activeIds = Set(hosts.map(\.id))

        // Start listeners for newly added hosts.
        for host in hosts where listenerTasks[host.id] == nil {
            let hostId = host.id
            listenerTasks[hostId] = Task { [weak self] in
                await self?.runListener(hostId: hostId, relayBase: relayBase)
            }
        }

        // Cancel listeners for removed hosts.
        for (hostId, task) in listenerTasks where !activeIds.contains(hostId) {
            task.cancel()
            listenerTasks.removeValue(forKey: hostId)
        }
    }

    private func stopAllListeners() {
        listenerTasks.values.forEach { $0.cancel() }
        listenerTasks.removeAll()
    }

    private func runListener(hostId: String, relayBase: String) async {
        while !Task.isCancelled {
            await connectAndListen(hostId: hostId, relayBase: relayBase)
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func connectAndListen(hostId: String, relayBase: String) async {
        let room = "\(hostId)-ctl"
        let authClient = RelayAuthClient(relayWebSocketBase: relayBase, apiBaseURL: AppRuntimeConfig.apiBaseURL)
        guard let url = try? await authClient.authorizedURL(hostId: hostId, room: room, role: "client-control") else {
            return
        }

        let wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask.resume()
        defer { wsTask.cancel(with: .goingAway, reason: nil) }

        // Ask for the current list immediately on connect.
        if let data = try? JSONSerialization.data(withJSONObject: ["type": "list_sessions"]),
           let json = String(data: data, encoding: .utf8) {
            try? await wsTask.send(.string(json))
        }

        while !Task.isCancelled {
            do {
                let message = try await wsTask.receive()
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                guard let data = text.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      parsed["type"] as? String == "sessions_list",
                      let array = parsed["sessions"] as? [[String: String]] else { continue }
                let summaries = array.compactMap { entry -> HostSessionSummary? in
                    guard let sessionId = entry["sessionId"], !sessionId.isEmpty else { return nil }
                    return HostSessionSummary(sessionId: sessionId, kind: entry["kind"].flatMap { SessionKind(rawValue: $0) })
                }
                applyRemoteSessions(summaries, hostId: hostId)
            } catch {
                break
            }
        }
    }

    // MARK: - Session Management

    func add(sessionId: String, hostId: String) {
        guard AppConfig.shared.isValid else {
            errorMessage = "Configuration required."
            return
        }
        guard let userId = currentUserId else {
            errorMessage = APIError.notAuthenticated.localizedDescription
            return
        }
        let trimmedId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }
        let newSession = SavedSession(sessionId: trimmedId, hostId: hostId)
        if sessions.contains(where: { $0.roomId == newSession.roomId }) { return }
        sessions.append(newSession)
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
        let relayBase = AppConfig.shared.relayWebSocketBase ?? ""
        if !relayBase.isEmpty {
            let client = HostControlClient(relayWebSocketBase: relayBase, apiBaseURL: AppRuntimeConfig.apiBaseURL)
            do {
                try await client.deleteSession(hostId: session.hostId, sessionId: session.sessionId)
            } catch {
                // If remote delete fails, we log it but proceed to delete locally
                // so the user isn't stuck with a zombie session in their UI.
                print("Remote delete failed for \(session.roomId): \(error.localizedDescription)")
            }
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
        "\(legacyHostsBaseKey)_\(userId)"
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
                // sessionId is nil in data persisted before the host-scoped room fix.
                // Fall back to the old roomId value, which was the bare session name.
                let sid = session.sessionId ?? session.roomId
                var saved = SavedSession(sessionId: sid, hostId: hostId)
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

    private func refreshDiscoveredHosts() async throws {
        let result = try await apiClient.discoverHosts()
        applyDiscoveredHosts(result.hosts)
    }

    private func clearPersistedState(for userId: String) {
        UserDefaults.standard.removeObject(forKey: storageKey(for: userId))
        UserDefaults.standard.removeObject(forKey: hostsStorageKey(for: userId))

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        if let cachesDir = caches.first?.appendingPathComponent("govibe_thumbs", isDirectory: true) {
            try? FileManager.default.removeItem(at: cachesDir)
        }
    }

    private func applyDiscoveredHosts(_ discoveredHosts: [DiscoveredHost]) {
        hosts = discoveredHosts.map { discovered in
            HostInfo(
                id: discovered.deviceId,
                name: discovered.displayName,
                capabilities: discovered.capabilities,
                isOnline: discovered.isOnline,
                lastSeenAt: discovered.lastSeenAt,
                lastOnlineAt: discovered.lastOnlineAt
            )
        }
        .sorted { lhs, rhs in
            switch ((lhs.isOnline ?? false), (rhs.isOnline ?? false)) {
            case (true, false):
                return true
            case (false, true):
                return false
            default:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }

        let activeHostIDs = Set(hosts.map(\.id))
        let originalCount = sessions.count
        sessions.removeAll { !activeHostIDs.contains($0.hostId) }
        if sessions.count != originalCount, let userId = currentUserId {
            save(for: userId)
        }
    }

    // MARK: - Auth

    private func ensureAuthenticated() async throws -> User {
        if let user = Auth.auth().currentUser {
            _ = try await user.getIDTokenResult(forcingRefresh: false)
            return user
        }
        throw APIError.notAuthenticated
    }
}

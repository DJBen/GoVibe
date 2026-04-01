import FirebaseAuth
import FirebaseFirestore
import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    private let sessionsBaseKey = "saved_sessions"
    private let legacyHostsBaseKey = "saved_hosts"

    var sessions: [SavedSession] = []
    var hosts: [HostInfo] = []
    var isLoading = false
    var errorMessage: String?
    var currentUserId: String?

    // Persistent per-host Firestore snapshot listeners for real-time session updates.
    private var snapshotListeners: [String: ListenerRegistration] = [:]
    // Real-time listener on the `devices` collection to detect new/removed hosts.
    private var hostDiscoveryListener: ListenerRegistration?

    private struct PersistedSavedSession: Decodable {
        let roomId: String
        let sessionId: String?   // nil in data persisted before the host-scoped room fix
        let hostId: String?
        let kind: SessionKind?
        let lastActiveAt: Date?
        let lastConversationSummary: String?
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
        } catch {
            sessions = []
            hosts = []
            errorMessage = error.localizedDescription
            return
        }

        // The Firestore host discovery listener is the single source of truth
        // for the host list. Its initial snapshot fires immediately (replacing the
        // old HTTP API call), and it keeps watching so hosts that register later
        // (e.g. macOS launched after iOS) appear automatically.
        startHostDiscoveryListener()
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
                if let remoteSummary = summary.lastConversationSummary,
                   sessions[index].lastConversationSummary != remoteSummary {
                    sessions[index].lastConversationSummary = remoteSummary
                    changed = true
                }
            } else {
                var s = SavedSession(sessionId: summary.sessionId, hostId: hostId)
                s.kind = summary.kind
                s.lastConversationSummary = summary.lastConversationSummary
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

    // MARK: - Firestore Snapshot Listeners

    /// Starts or stops per-host Firestore snapshot listeners so each host has exactly
    /// one real-time listener on its `hostedSessions` subcollection.
    private func reconcileFirestoreListeners() {
        let db = Firestore.firestore()
        let activeIds = Set(hosts.map(\.id))
        let uid = currentUserId ?? ""

        for host in hosts where snapshotListeners[host.id] == nil {
            let hostId = host.id
            // Query must filter on ownerUid to satisfy Firestore security rules.
            let reg = db.collection("devices").document(hostId)
                        .collection("hostedSessions")
                        .whereField("ownerUid", isEqualTo: uid)
                        .addSnapshotListener { [weak self] snap, _ in
                guard let self, let snap else { return }
                Task { @MainActor in
                    self.applyFirestoreSnapshot(snap, hostId: hostId)
                }
            }
            snapshotListeners[hostId] = reg
        }

        for (hostId, reg) in snapshotListeners where !activeIds.contains(hostId) {
            reg.remove()
            snapshotListeners.removeValue(forKey: hostId)
        }
    }

    private func applyFirestoreSnapshot(_ snapshot: QuerySnapshot, hostId: String) {
        let summaries: [HostSessionSummary] = snapshot.documents.compactMap { doc in
            let data = doc.data()
            guard let sid = data["sessionId"] as? String, !sid.isEmpty else { return nil }
            let kind = (data["kind"] as? String).flatMap { SessionKind(rawValue: $0) }
            let summary = data["lastConversationSummary"] as? String
            return HostSessionSummary(sessionId: sid, kind: kind, lastConversationSummary: summary)
        }
        applyRemoteSessions(summaries, hostId: hostId)
    }

    private func stopAllListeners() {
        hostDiscoveryListener?.remove()
        hostDiscoveryListener = nil
        snapshotListeners.values.forEach { $0.remove() }
        snapshotListeners.removeAll()
    }

    // MARK: - Host Discovery Listener

    /// Starts a Firestore snapshot listener on the user's mac host devices so the
    /// iOS app is notified in real time when a host registers or goes away.
    private func startHostDiscoveryListener() {
        guard hostDiscoveryListener == nil, let uid = currentUserId else { return }
        let db = Firestore.firestore()
        // Query only on ownerUid (required by security rules) and filter the
        // remaining host criteria client-side. This avoids needing a composite
        // Firestore index and the devices collection per-user is tiny.
        hostDiscoveryListener = db.collection("devices")
            .whereField("ownerUid", isEqualTo: uid)
            .addSnapshotListener { [weak self] snap, error in
                guard let self else { return }
                if let error {
                    print("Host discovery listener error: \(error.localizedDescription)")
                    return
                }
                guard let snap else { return }
                Task { @MainActor in
                    self.applyHostDiscoverySnapshot(snap)
                }
            }
    }

    private func applyHostDiscoverySnapshot(_ snapshot: QuerySnapshot) {
        let discoveredHosts: [DiscoveredHost] = snapshot.documents.compactMap { doc in
            let data = doc.data()
            // Mirror the backend: only mac hosts with discoveryVisible != false.
            guard data["platform"] as? String == "mac" else { return nil }
            guard data["isHost"] as? Bool == true else { return nil }
            if let visible = data["discoveryVisible"] as? Bool, !visible { return nil }

            return DiscoveredHost(
                deviceId: doc.documentID,
                displayName: data["displayName"] as? String ?? doc.documentID,
                capabilities: data["capabilities"] as? [String] ?? [],
                appVersion: data["appVersion"] as? String,
                osVersion: data["osVersion"] as? String
            )
        }
        applyDiscoveredHosts(discoveredHosts)
        reconcileFirestoreListeners()
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
    /// - Parameter killTmux: If `true`, the host kills the underlying tmux session. If `false`, GoVibe detaches without killing tmux.
    func deleteSession(_ session: SavedSession, killTmux: Bool = true) async {
        let relayBase = AppConfig.shared.relayWebSocketBase ?? ""
        if !relayBase.isEmpty {
            let client = HostControlClient(relayWebSocketBase: relayBase, apiBaseURL: AppRuntimeConfig.apiBaseURL)
            do {
                try await client.deleteSession(hostId: session.hostId, sessionId: session.sessionId, killTmux: killTmux)
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
                saved.lastActiveAt = session.lastActiveAt
                saved.lastConversationSummary = session.lastConversationSummary
                return saved
            }
        } catch {
            sessions = []
            errorMessage = "Failed to read local session list."
        }
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
                capabilities: discovered.capabilities
            )
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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

import FirebaseFirestore
import Foundation

/// Writes hosted session metadata to Firestore so iOS can discover sessions
/// via addSnapshotListener instead of the relay control channel.
actor HostSessionSync {
    private var _db: Firestore?
    private var db: Firestore {
        if _db == nil { _db = Firestore.firestore() }
        return _db!
    }
    private var hostId: String = ""
    private var ownerUid: String = ""

    func configure(hostId: String, ownerUid: String) {
        self.hostId = hostId
        self.ownerUid = ownerUid
    }

    func upsert(_ descriptor: HostedSessionDescriptor) async {
        guard !hostId.isEmpty, !ownerUid.isEmpty else { return }
        let ref = db.collection("devices").document(hostId)
                    .collection("hostedSessions").document(descriptor.sessionId)
        try? await ref.setData([
            "ownerUid":    ownerUid,
            "sessionId":   descriptor.sessionId,
            "kind":        descriptor.kind.rawValue,
            "displayName": descriptor.displayName,
            "state":       descriptor.state.rawValue,
            "createdAt":   FieldValue.serverTimestamp(),
            "updatedAt":   FieldValue.serverTimestamp(),
        ], merge: true)
    }

    func remove(sessionId: String) async {
        guard !hostId.isEmpty else { return }
        try? await db.collection("devices").document(hostId)
                     .collection("hostedSessions").document(sessionId).delete()
    }

    /// Full reconcile: upserts current sessions and deletes any Firestore docs
    /// that no longer exist locally, preventing orphaned docs from prior runs.
    func syncAll(_ descriptors: [HostedSessionDescriptor]) async {
        guard !hostId.isEmpty, !ownerUid.isEmpty else { return }
        let base = db.collection("devices").document(hostId).collection("hostedSessions")

        // Fetch existing docs so we can delete stale ones.
        // Query must filter on ownerUid to satisfy Firestore security rules.
        let existingSnap = try? await base.whereField("ownerUid", isEqualTo: ownerUid).getDocuments()
        let localIds = Set(descriptors.map(\.sessionId))

        let batch = db.batch()
        for d in descriptors {
            batch.setData([
                "ownerUid": ownerUid, "sessionId": d.sessionId,
                "kind": d.kind.rawValue, "displayName": d.displayName,
                "state": d.state.rawValue,
                "createdAt": FieldValue.serverTimestamp(),
                "updatedAt": FieldValue.serverTimestamp(),
            ], forDocument: base.document(d.sessionId), merge: true)
        }
        // Remove Firestore docs not present in local state.
        for doc in existingSnap?.documents ?? [] where !localIds.contains(doc.documentID) {
            batch.deleteDocument(doc.reference)
        }
        try? await batch.commit()
    }

    func removeAll() async {
        guard !hostId.isEmpty else { return }
        guard let snap = try? await db.collection("devices").document(hostId)
                                      .collection("hostedSessions")
                                      .whereField("ownerUid", isEqualTo: ownerUid).getDocuments() else { return }
        guard !snap.documents.isEmpty else { return }
        let batch = db.batch()
        snap.documents.forEach { batch.deleteDocument($0.reference) }
        try? await batch.commit()
    }
}

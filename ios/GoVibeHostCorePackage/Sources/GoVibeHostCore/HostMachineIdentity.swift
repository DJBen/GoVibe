import CryptoKit
import Foundation
import Security

enum HostMachineIdentity {
    private static let service = "dev.govibe.host.machine-identity"
    private static let account = "default-host-id"

    static func resolveHostID(
        userID: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let hostId = environment["GOVIBE_HOST_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostId.isEmpty {
            return hostId
        }

        let baseID: String
        if let existing = loadHostID(), !existing.isEmpty {
            baseID = existing
        } else {
            let generated = UUID().uuidString
            saveHostID(generated)
            baseID = generated
        }

        guard let userID, !userID.isEmpty else {
            return baseID
        }

        let digest = SHA256.hash(data: Data("\(userID)|\(baseID)".utf8))
        let scopedSuffix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "host-\(scopedSuffix)"
    }

    private static func loadHostID() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let hostId = String(data: data, encoding: .utf8) else {
            return nil
        }
        return hostId
    }

    private static func saveHostID(_ hostId: String) {
        let data = Data(hostId.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}

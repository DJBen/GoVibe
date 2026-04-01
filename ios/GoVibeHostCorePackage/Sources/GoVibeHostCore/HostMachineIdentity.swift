import Crypto
import Foundation
#if canImport(Security)
import Security
#endif

public enum HostMachineIdentity {
    private static let directoryName = ".govibe"
    private static let fileName = "host-id"

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)
    }

    public static func resolveHostID(
        userID: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let hostId = environment["GOVIBE_HOST_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostId.isEmpty {
            return hostId
        }

        // One-time migration from Keychain to file (macOS only).
        migrateFromKeychainIfNeeded()

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

    public static func deleteHostID() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - File Storage

    private static func loadHostID() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let hostId = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !hostId.isEmpty else {
            return nil
        }
        return hostId
    }

    private static func saveHostID(_ hostId: String) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(hostId.utf8).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    // MARK: - Keychain Migration (macOS only)

    private static func migrateFromKeychainIfNeeded() {
        #if canImport(Security)
        guard loadHostID() == nil else { return }
        guard let keychainID = loadFromKeychain() else { return }
        saveHostID(keychainID)
        deleteFromKeychain()
        #endif
    }

    #if canImport(Security)
    private static let keychainService = "dev.govibe.host.machine-identity"
    private static let keychainAccount = "default-host-id"

    private static func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let hostId = String(data: data, encoding: .utf8),
              !hostId.isEmpty else {
            return nil
        }
        return hostId
    }

    private static func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
    #endif
}

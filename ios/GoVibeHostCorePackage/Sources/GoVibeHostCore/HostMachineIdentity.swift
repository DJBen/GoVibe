import Crypto
import Foundation
#if canImport(Security)
import Security
#endif

public enum HostMachineIdentity {
    #if canImport(Security)
    private static let keychainService = "dev.govibe.host.machine-identity"
    private static let keychainAccount = "default-host-id"
    #endif

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

        // One-time migration from file back to Keychain (macOS only).
        migrateFromFileIfNeeded()

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
        #if canImport(Security)
        deleteFromKeychain()
        #else
        try? FileManager.default.removeItem(at: fileURL)
        #endif
    }

    // MARK: - Storage

    private static func loadHostID() -> String? {
        #if canImport(Security)
        return loadFromKeychain()
        #else
        return loadFromFile()
        #endif
    }

    private static func saveHostID(_ hostId: String) {
        #if canImport(Security)
        saveToKeychain(hostId)
        #else
        saveToFile(hostId)
        #endif
    }

    // MARK: - File Storage (Linux)

    private static func loadFromFile() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let hostId = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !hostId.isEmpty else {
            return nil
        }
        return hostId
    }

    private static func saveToFile(_ hostId: String) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(hostId.utf8).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func deleteFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Keychain Storage (Apple platforms)

    #if canImport(Security)
    private static func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: false,
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

    private static func saveToKeychain(_ hostId: String) {
        let data = Data(hostId.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: false,
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

    private static func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: false,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func migrateFromFileIfNeeded() {
        guard loadFromKeychain() == nil else { return }
        guard let fileID = loadFromFile() else { return }
        saveToKeychain(fileID)
        deleteFile()
    }
    #else
    private static func migrateFromFileIfNeeded() {}
    #endif
}

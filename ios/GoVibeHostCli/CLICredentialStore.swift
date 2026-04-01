import Foundation

struct CLICredentials: Codable, Sendable {
    var firebaseIdToken: String
    var firebaseRefreshToken: String
    var expiresAt: Date
    var uid: String
    var email: String?
    var displayName: String?
}

enum CLICredentialStoreError: LocalizedError {
    case noCredentials
    case corruptedFile

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No saved credentials. Sign in first."
        case .corruptedFile:
            return "Credentials file is corrupted."
        }
    }
}

/// Persists Firebase credentials to `~/.govibe/credentials.json` with 0600 permissions.
struct CLICredentialStore: Sendable {
    private static let directoryName = ".govibe"
    private static let fileName = "credentials.json"

    private var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(Self.directoryName)
    }

    private var fileURL: URL {
        directoryURL.appendingPathComponent(Self.fileName)
    }

    func load() throws -> CLICredentials {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CLICredentialStoreError.noCredentials
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(CLICredentials.self, from: data)
        } catch {
            throw CLICredentialStoreError.corruptedFile
        }
    }

    func save(_ credentials: CLICredentials) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(credentials)
        try data.write(to: fileURL, options: .atomic)

        // Set file permissions to 0600 (owner read/write only)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    var hasCredentials: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }
}

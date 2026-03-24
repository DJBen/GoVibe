@preconcurrency import FirebaseAuth
import Foundation

public struct HostRegistrationPayload: Sendable {
    public let deviceId: String
    public let displayName: String
    public let capabilities: [String]
    public let discoveryVisible: Bool
    public let appVersion: String?
    public let osVersion: String?

    public init(
        deviceId: String,
        displayName: String,
        capabilities: [String],
        discoveryVisible: Bool,
        appVersion: String?,
        osVersion: String?
    ) {
        self.deviceId = deviceId
        self.displayName = displayName
        self.capabilities = capabilities
        self.discoveryVisible = discoveryVisible
        self.appVersion = appVersion
        self.osVersion = osVersion
    }
}

actor HostAPIClient {
    private let baseURL: URL
    private let decoder = JSONDecoder()

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func registerHost(_ payload: HostRegistrationPayload) async throws {
        _ = try await request(
            path: "/device/register",
            body: [
                "deviceId": payload.deviceId,
                "platform": "mac",
                "displayName": payload.displayName,
                "isHost": true,
                "discoveryVisible": payload.discoveryVisible,
                "capabilities": payload.capabilities,
                "appVersion": payload.appVersion as Any,
                "osVersion": payload.osVersion as Any,
            ],
            responseType: HostOKResponse.self
        )
    }

    func heartbeat(_ payload: HostRegistrationPayload) async throws {
        _ = try await request(
            path: "/device/heartbeat",
            body: [
                "deviceId": payload.deviceId,
                "discoveryVisible": payload.discoveryVisible,
                "capabilities": payload.capabilities,
                "appVersion": payload.appVersion as Any,
                "osVersion": payload.osVersion as Any,
            ],
            responseType: HostOKResponse.self
        )
    }

    func resetUser() async throws {
        _ = try await request(
            path: "/user/reset",
            body: [:],
            responseType: HostOKResponse.self
        )
    }

    func issueRelayToken(deviceId: String, hostId: String, room: String, role: String) async throws -> HostRelayTokenResponse {
        try await request(
            path: "/relay/token",
            body: [
                "deviceId": deviceId,
                "hostId": hostId,
                "room": room,
                "role": role
            ],
            responseType: HostRelayTokenResponse.self
        )
    }

    private func request<T: Decodable>(path: String, method: String = "POST", body: [String: Any], responseType: T.Type) async throws -> T {
        guard let user = Auth.auth().currentUser else {
            throw HostAPIError.notAuthenticated
        }

        let token = try await user.getIDTokenResult().token
        var urlRequest = URLRequest(url: baseURL.appending(path: path))
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HostAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HostAPIError.httpError(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        return try decoder.decode(responseType, from: data)
    }
}

private struct HostOKResponse: Decodable {
    let ok: Bool
}

struct HostRelayTokenResponse: Decodable {
    let token: String
}

enum HostAPIError: Error, LocalizedError {
    case notAuthenticated
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Host authentication is required."
        case .invalidResponse:
            return "The host service returned an invalid response."
        case .httpError(let status, let detail):
            return detail.isEmpty ? "Server error (\(status))." : "Server error (\(status)): \(detail)"
        }
    }
}

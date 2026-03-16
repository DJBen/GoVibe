import FirebaseAuth
import Foundation

actor GoVibeAPIClient {
    private let baseURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func sessionCreate(ownerDeviceId: String, peerDeviceId: String) async throws -> SessionCreateResponse {
        try await request(
            path: "/session/create",
            body: [
                "ownerDeviceId": ownerDeviceId,
                "peerDeviceId": peerDeviceId,
                "relayRequired": false,
                "icePolicy": "all"
            ],
            responseType: SessionCreateResponse.self
        )
    }

    func discoverSessions(ownerDeviceId: String? = nil) async throws -> SessionDiscoveryResponse {
        var body: [String: Any] = [:]
        if let ownerDeviceId {
            body["ownerDeviceId"] = ownerDeviceId
        }
        return try await request(
            path: "/session/discover",
            method: "POST",
            body: body,
            responseType: SessionDiscoveryResponse.self
        )
    }

    func registerFCMToken(_ token: String, deviceId: String) async throws {
        _ = try await request(
            path: "/device/fcmToken",
            body: ["deviceId": deviceId, "fcmToken": token],
            responseType: OkResponse.self
        )
    }

    private func request<T: Decodable>(path: String, method: String = "POST", body: [String: Any]?, responseType: T.Type) async throws -> T {
        guard let user = Auth.auth().currentUser else {
            throw APIError.notAuthenticated
        }

        let token = try await user.getIDTokenResult().token
        var urlRequest = URLRequest(url: baseURL.appending(path: path))
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        return try decoder.decode(responseType, from: data)
    }
}

private struct OkResponse: Decodable {
    let ok: Bool
}

enum APIError: Error {
    case notAuthenticated
    case invalidResponse
    case httpError(Int, String)
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Authentication required. Please sign in and try again."
        case .invalidResponse:
            return "Received an invalid response from server."
        case .httpError(let status, let detail):
            if detail.isEmpty {
                return "Server error (\(status))."
            }
            return "Server error (\(status)): \(detail)"
        }
    }
}

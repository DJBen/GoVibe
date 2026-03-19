import Foundation

enum RelayAuthError: LocalizedError {
    case apiUnavailable
    case invalidRelayURL
    case invalidComposedURL

    var errorDescription: String? {
        switch self {
        case .apiUnavailable:
            return "Relay auth is unavailable because the API base URL is not configured."
        case .invalidRelayURL:
            return "Invalid relay URL."
        case .invalidComposedURL:
            return "Failed to compose an authenticated relay URL."
        }
    }
}

struct RelayAuthClient {
    let relayWebSocketBase: String
    let apiBaseURL: URL?

    func authorizedURL(hostId: String, room: String, role: String) async throws -> URL {
        guard let apiBaseURL else {
            throw RelayAuthError.apiUnavailable
        }

        let apiClient = GoVibeAPIClient(baseURL: apiBaseURL)
        let tokenResponse = try await apiClient.issueRelayToken(
            deviceId: LocalDevice.iosDeviceID,
            hostId: hostId,
            room: room,
            role: role
        )

        guard var components = URLComponents(string: relayWebSocketBase) else {
            throw RelayAuthError.invalidRelayURL
        }
        components.queryItems = [
            URLQueryItem(name: "room", value: room),
            URLQueryItem(name: "token", value: tokenResponse.token),
        ]
        guard let url = components.url else {
            throw RelayAuthError.invalidComposedURL
        }
        return url
    }
}

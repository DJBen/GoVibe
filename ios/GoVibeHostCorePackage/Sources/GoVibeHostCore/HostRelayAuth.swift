import Foundation

enum HostRelayAuthError: LocalizedError {
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

struct HostRelayAuth {
    let relayWebSocketBase: String
    let apiBaseURL: URL?

    func authorizedURL(deviceId: String, hostId: String, room: String, role: String) async throws -> URL {
        guard let apiBaseURL else {
            throw HostRelayAuthError.apiUnavailable
        }

        try await HostAuthController.shared.ensureHostRegistrationReady()

        let apiClient = HostAPIClient(baseURL: apiBaseURL)
        let tokenResponse = try await apiClient.issueRelayToken(
            deviceId: deviceId,
            hostId: hostId,
            room: room,
            role: role
        )

        guard var components = URLComponents(string: relayWebSocketBase) else {
            throw HostRelayAuthError.invalidRelayURL
        }
        components.queryItems = [
            URLQueryItem(name: "room", value: room),
            URLQueryItem(name: "token", value: tokenResponse.token),
        ]
        guard let url = components.url else {
            throw HostRelayAuthError.invalidComposedURL
        }
        return url
    }
}

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

public struct HostRelayAuth {
    let relayWebSocketBase: String
    let apiBaseURL: URL?
    let tokenProvider: HostTokenProvider
    var onEnsureRegistration: (@Sendable () async throws -> Void)?

    public init(
        relayWebSocketBase: String,
        apiBaseURL: URL?,
        tokenProvider: HostTokenProvider = FirebaseSDKTokenProvider(),
        onEnsureRegistration: (@Sendable () async throws -> Void)? = nil
    ) {
        self.relayWebSocketBase = relayWebSocketBase
        self.apiBaseURL = apiBaseURL
        self.tokenProvider = tokenProvider
        self.onEnsureRegistration = onEnsureRegistration
    }

    public func authorizedURL(deviceId: String, hostId: String, room: String, role: String) async throws -> URL {
        guard let apiBaseURL else {
            throw HostRelayAuthError.apiUnavailable
        }

        try await onEnsureRegistration?()

        let apiClient = HostAPIClient(baseURL: apiBaseURL, tokenProvider: tokenProvider)
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

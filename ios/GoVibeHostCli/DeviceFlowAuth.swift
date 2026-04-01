import Foundation

struct GoogleDeviceFlowResult: Sendable {
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

enum DeviceFlowError: LocalizedError {
    case missingClientConfig
    case deviceCodeRequestFailed(String)
    case accessDenied
    case expired
    case pollingFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingClientConfig:
            return "Google OAuth client ID or secret is not configured."
        case .deviceCodeRequestFailed(let detail):
            return "Failed to request device code: \(detail)"
        case .accessDenied:
            return "Sign-in was denied. Please try again."
        case .expired:
            return "Sign-in code expired. Please try again."
        case .pollingFailed(let detail):
            return "Token polling failed: \(detail)"
        }
    }
}

/// Implements Google OAuth 2.0 Device Authorization Grant (RFC 8628).
struct DeviceFlowAuth {
    private static let deviceCodeURL = "https://oauth2.googleapis.com/device/code"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let scope = "openid email profile"
    private static let grantType = "urn:ietf:params:oauth:device_code"

    let clientID: String
    let clientSecret: String

    /// Runs the full device flow: requests a code, prints instructions, polls for completion.
    func signIn() async throws -> GoogleDeviceFlowResult {
        let deviceCode = try await requestDeviceCode()

        print()
        print("To sign in, visit:  \(deviceCode.verification_url)")
        print("Enter this code:    \(deviceCode.user_code)")
        print()

        return try await pollForToken(deviceCode: deviceCode)
    }

    // MARK: - Step 1: Request Device Code

    private struct DeviceCodeResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_url: String
        let expires_in: Int
        let interval: Int
    }

    private func requestDeviceCode() async throws -> DeviceCodeResponse {
        var request = URLRequest(url: URL(string: Self.deviceCodeURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "client_id=\(clientID)&scope=\(Self.scope)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DeviceFlowError.deviceCodeRequestFailed(body)
        }

        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    // MARK: - Step 2: Poll for Token

    private struct TokenResponse: Decodable {
        let id_token: String?
        let access_token: String?
        let refresh_token: String?
        let expires_in: Int?
    }

    private struct TokenErrorResponse: Decodable {
        let error: String?
    }

    private func pollForToken(deviceCode: DeviceCodeResponse) async throws -> GoogleDeviceFlowResult {
        var interval = TimeInterval(max(deviceCode.interval, 5))
        let deadline = Date().addingTimeInterval(TimeInterval(deviceCode.expires_in))

        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))

            var request = URLRequest(url: URL(string: Self.tokenURL)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let body = [
                "client_id=\(clientID)",
                "client_secret=\(clientSecret)",
                "device_code=\(deviceCode.device_code)",
                "grant_type=\(Self.grantType)",
            ].joined(separator: "&")
            request.httpBody = body.data(using: .utf8)

            let (data, _) = try await URLSession.shared.data(for: request)

            // Try to decode a successful token response
            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            if let idToken = tokenResponse.id_token,
               let accessToken = tokenResponse.access_token,
               let refreshToken = tokenResponse.refresh_token,
               let expiresIn = tokenResponse.expires_in {
                return GoogleDeviceFlowResult(
                    idToken: idToken,
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    expiresIn: expiresIn
                )
            }

            // Check for error states
            let errorResponse = try JSONDecoder().decode(TokenErrorResponse.self, from: data)
            switch errorResponse.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
                continue
            case "access_denied":
                throw DeviceFlowError.accessDenied
            case "expired_token":
                throw DeviceFlowError.expired
            default:
                throw DeviceFlowError.pollingFailed(errorResponse.error ?? "unknown error")
            }
        }

        throw DeviceFlowError.expired
    }
}

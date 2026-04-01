import Foundation

struct FirebaseAuthResult: Sendable {
    let localId: String        // Firebase UID
    let idToken: String        // Firebase ID token
    let refreshToken: String
    let expiresIn: Int
    let email: String?
    let displayName: String?
}

enum FirebaseRESTError: LocalizedError {
    case missingAPIKey
    case signInFailed(String)
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Firebase API key is not configured."
        case .signInFailed(let detail):
            return "Firebase sign-in failed: \(detail)"
        case .refreshFailed(let detail):
            return "Firebase token refresh failed: \(detail)"
        }
    }
}

/// Exchanges third-party tokens for Firebase Auth credentials via the REST API.
struct FirebaseRESTAuth {
    let apiKey: String

    /// Exchanges a Google ID token for Firebase Auth credentials.
    func signInWithGoogle(idToken: String) async throws -> FirebaseAuthResult {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(apiKey)")!

        let body: [String: Any] = [
            "postBody": "id_token=\(idToken)&providerId=google.com",
            "requestUri": "http://localhost",
            "returnIdpCredential": true,
            "returnSecureToken": true,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw FirebaseRESTError.signInFailed(detail)
        }

        let decoded = try JSONDecoder().decode(SignInResponse.self, from: data)
        return FirebaseAuthResult(
            localId: decoded.localId,
            idToken: decoded.idToken,
            refreshToken: decoded.refreshToken,
            expiresIn: Int(decoded.expiresIn) ?? 3600,
            email: decoded.email,
            displayName: decoded.displayName
        )
    }

    /// Refreshes an expired Firebase ID token using a refresh token.
    func refreshToken(_ refreshToken: String) async throws -> FirebaseAuthResult {
        let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(apiKey)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=refresh_token&refresh_token=\(refreshToken)".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw FirebaseRESTError.refreshFailed(detail)
        }

        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        return FirebaseAuthResult(
            localId: decoded.user_id,
            idToken: decoded.id_token,
            refreshToken: decoded.refresh_token,
            expiresIn: Int(decoded.expires_in) ?? 3600,
            email: nil,
            displayName: nil
        )
    }

    // MARK: - Response types

    private struct SignInResponse: Decodable {
        let localId: String
        let idToken: String
        let refreshToken: String
        let expiresIn: String
        let email: String?
        let displayName: String?
    }

    private struct RefreshResponse: Decodable {
        let user_id: String
        let id_token: String
        let refresh_token: String
        let expires_in: String
    }
}

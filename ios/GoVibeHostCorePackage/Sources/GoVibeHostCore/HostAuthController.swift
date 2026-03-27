import AppKit
import AuthenticationServices
import CryptoKit
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import Foundation
@preconcurrency import GoogleSignIn
import Observation

public struct HostAuthenticatedUser: Equatable, Sendable {
    public let uid: String
    public let email: String?
    public let displayName: String?
}

@MainActor
@Observable
public final class HostAuthController {
    public static let shared = HostAuthController()

    public private(set) var currentUser: HostAuthenticatedUser?
    public private(set) var isBusy = false
    public private(set) var hasAttemptedRestore = false
    public var errorMessage: String?

    @ObservationIgnored
    private var authStateHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored
    private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored
    private var apiClient: HostAPIClient?
    @ObservationIgnored
    private var registrationTask: Task<Void, Error>?
    @ObservationIgnored
    private var latestRegistrationPayload: HostRegistrationPayload?

    public var isAuthenticated: Bool {
        currentUser != nil
    }

    public init() {
        configureFirebaseIfNeeded()
        apiClient = HostConfig.shared.apiBaseURL.map { HostAPIClient(baseURL: $0) }
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.updateCurrentUser(user)
            }
        }
        updateCurrentUser(Auth.auth().currentUser)
    }

    public func refreshConfig() {
        apiClient = HostConfig.shared.apiBaseURL.map { HostAPIClient(baseURL: $0) }
    }

    public func restoreSessionIfPossible() async {
        guard !hasAttemptedRestore else { return }
        hasAttemptedRestore = true

        if Auth.auth().currentUser != nil {
            updateCurrentUser(Auth.auth().currentUser)
            return
        }

        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let googleUser = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            try await signInToFirebase(with: googleUser)
            errorMessage = nil
        } catch {
            errorMessage = "Google session restore failed: \(error.localizedDescription)"
            GIDSignIn.sharedInstance.signOut()
        }
    }

    public func signIn() async {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            errorMessage = "Unable to present Google Sign-In."
            return
        }

        HostAnalytics.log("host_auth_method_chosen", parameters: ["method": "google"])
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: window)
            try await signInToFirebase(with: result.user)
            errorMessage = nil
            HostAnalytics.log("host_auth_success", parameters: ["method": "google"])
        } catch {
            errorMessage = "Google sign-in failed: \(error.localizedDescription)"
            HostAnalytics.log("host_auth_failure", parameters: ["method": "google", "error_message": error.localizedDescription])
        }
    }

    public func signInWithAppleWeb() async {
        HostAnalytics.log("host_auth_method_chosen", parameters: ["method": "apple_web"])
        guard let apiBaseURL = HostConfig.shared.apiBaseURL else {
            errorMessage = "API base URL is not configured. Set GCP project ID and region first."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let nonce = Self.randomNonceString()
            let hashedNonce = Self.sha256(nonce)
            let state = Self.randomNonceString()
            let redirectURI = apiBaseURL.appendingPathComponent("apple-auth/callback").absoluteString

            var components = URLComponents(string: "https://appleid.apple.com/auth/authorize")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: "dev.govibe.ios.DJBen.signinWithApple"),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "response_type", value: "code id_token"),
                URLQueryItem(name: "response_mode", value: "form_post"),
                URLQueryItem(name: "scope", value: "name email"),
                URLQueryItem(name: "nonce", value: hashedNonce),
                URLQueryItem(name: "state", value: state),
            ]

            guard let authURL = components.url else {
                throw HostAuthError.invalidAppleAuthURL
            }

            let callbackURL = try await startWebAuthSession(url: authURL, callbackScheme: "govibe-host")

            guard let urlComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let idToken = urlComponents.queryItems?.first(where: { $0.name == "id_token" })?.value
            else {
                throw HostAuthError.missingAppleIDToken
            }

            var fullName: PersonNameComponents?
            if let userJSON = urlComponents.queryItems?.first(where: { $0.name == "user" })?.value,
               let userData = userJSON.data(using: .utf8),
               let userDict = try? JSONSerialization.jsonObject(with: userData) as? [String: Any],
               let nameDict = userDict["name"] as? [String: String] {
                var name = PersonNameComponents()
                name.givenName = nameDict["firstName"]
                name.familyName = nameDict["lastName"]
                fullName = name
            }

            let credential = OAuthProvider.appleCredential(
                withIDToken: idToken,
                rawNonce: nonce,
                fullName: fullName
            )
            let result = try await Auth.auth().signIn(with: credential)
            updateCurrentUser(result.user)
            errorMessage = nil
            HostAnalytics.log("host_auth_success", parameters: ["method": "apple_web"])
        } catch HostAuthError.webAuthCancelled {
            errorMessage = nil
        } catch {
            errorMessage = "Apple sign-in failed: \(error.localizedDescription)"
            HostAnalytics.log("host_auth_failure", parameters: ["method": "apple_web", "error_message": error.localizedDescription])
        }
    }

    public func signOut() {
        HostAnalytics.log("host_sign_out")
        HostAnalytics.setUserID(nil)
        heartbeatTask?.cancel()
        heartbeatTask = nil
        registrationTask?.cancel()
        registrationTask = nil
        do {
            try Auth.auth().signOut()
        } catch {
            errorMessage = "Sign out failed: \(error.localizedDescription)"
        }
        GIDSignIn.sharedInstance.signOut()
        updateCurrentUser(nil)
    }

    public func startHostRegistration(
        hostId: String,
        displayName: String,
        capabilities: [String],
        discoveryVisible: Bool
    ) {
        heartbeatTask?.cancel()
        guard isAuthenticated else { return }

        let payload = HostRegistrationPayload(
            deviceId: hostId,
            displayName: displayName,
            capabilities: capabilities,
            discoveryVisible: discoveryVisible,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        latestRegistrationPayload = payload
        registrationTask = nil

        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            await self.runHostRegistrationLoop()
        }
    }

    public func ensureHostRegistrationReady() async throws {
        guard let apiClient else {
            throw HostAuthError.apiUnavailable
        }
        guard Auth.auth().currentUser != nil else {
            throw HostAuthError.notAuthenticated
        }
        guard let payload = latestRegistrationPayload else {
            throw HostAuthError.registrationNotConfigured
        }
        if let task = registrationTask {
            try await task.value
            return
        }

        let task = Task {
            try await apiClient.registerHost(payload)
            HostAnalytics.log("host_registered")
        }
        registrationTask = task

        do {
            try await task.value
        } catch {
            registrationTask = nil
            throw error
        }
    }

    private func runHostRegistrationLoop() async {
        guard let apiClient else {
            errorMessage = "Host API base URL is not configured."
            return
        }

        do {
            try await ensureHostRegistrationReady()
            errorMessage = nil
        } catch {
            errorMessage = "Host registration failed: \(error.localizedDescription)"
            return
        }

        let db = Firestore.firestore()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
                guard let payload = latestRegistrationPayload else { continue }
                var update: [String: Any] = [
                    "lastSeenAt": FieldValue.serverTimestamp(),
                    "lastOnlineAt": FieldValue.serverTimestamp(),
                ]
                update["discoveryVisible"] = payload.discoveryVisible
                try await db.collection("devices").document(payload.deviceId).updateData(update)
            } catch is CancellationError {
                break
            } catch {
                await MainActor.run {
                    self.errorMessage = "Host heartbeat failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private nonisolated func startWebAuthSession(url: URL, callbackScheme: String) async throws -> URL {
        try await webAuthSessionRun(url: url, callbackScheme: callbackScheme)
    }

    private static func randomNonceString(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            for random in randoms where remainingLength > 0 {
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func signInToFirebase(with googleUser: GIDGoogleUser) async throws {
        guard let idToken = googleUser.idToken?.tokenString else {
            throw HostAuthError.missingGoogleIDToken
        }

        let accessToken = googleUser.accessToken.tokenString
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        let result = try await Auth.auth().signIn(with: credential)
        updateCurrentUser(result.user)
    }

    private func configureFirebaseIfNeeded() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }

    private func updateCurrentUser(_ user: User?) {
        if let user {
            currentUser = HostAuthenticatedUser(
                uid: user.uid,
                email: user.email,
                displayName: user.displayName
            )
            HostAnalytics.setUserID(user.uid)
            HostAnalytics.setUserProperties()
        } else {
            currentUser = nil
        }
    }

}

/// Runs an ASWebAuthenticationSession entirely outside any actor context so that
/// the completion handler — which the system calls on an XPC background queue —
/// carries no actor-isolation assertion.
private func webAuthSessionRun(url: URL, callbackScheme: String) async throws -> URL {
    final class Box: @unchecked Sendable {
        var session: ASWebAuthenticationSession?
        var context: NSObject? // prevent deallocation of presentation context
    }
    let box = Box()

    // Build the completion handler here (nonisolated file scope) so Swift
    // does NOT infer @MainActor isolation on it.
    return try await withCheckedThrowingContinuation { continuation in
        let handler: @Sendable (URL?, (any Error)?) -> Void = { callbackURL, error in
            box.session = nil
            box.context = nil
            if let error = error as? ASWebAuthenticationSessionError,
               error.code == .canceledLogin {
                continuation.resume(throwing: HostAuthError.webAuthCancelled)
                return
            }
            if let error {
                continuation.resume(throwing: error)
                return
            }
            guard let callbackURL else {
                continuation.resume(throwing: HostAuthError.missingAppleIDToken)
                return
            }
            continuation.resume(returning: callbackURL)
        }

        DispatchQueue.main.async {
            let ctx = WebAuthPresentationContext()
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme,
                completionHandler: handler
            )
            session.presentationContextProvider = ctx
            session.prefersEphemeralWebBrowserSession = true
            box.session = session
            box.context = ctx
            session.start()
        }
    }
}

private final class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
    }
}

private enum HostAuthError: LocalizedError {
    case missingGoogleIDToken
    case apiUnavailable
    case notAuthenticated
    case registrationNotConfigured
    case invalidAppleAuthURL
    case missingAppleIDToken
    case webAuthCancelled

    var errorDescription: String? {
        switch self {
        case .missingGoogleIDToken:
            return "Google sign-in returned no ID token."
        case .apiUnavailable:
            return "Host API base URL is not configured."
        case .notAuthenticated:
            return "Authentication required. Sign in and try again."
        case .registrationNotConfigured:
            return "Host registration is not configured yet."
        case .invalidAppleAuthURL:
            return "Failed to construct Apple sign-in URL."
        case .missingAppleIDToken:
            return "Apple sign-in did not return an ID token."
        case .webAuthCancelled:
            return nil
        }
    }
}

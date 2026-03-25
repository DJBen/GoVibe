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
    @ObservationIgnored
    private var currentAppleNonce: String?

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

        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: window)
            try await signInToFirebase(with: result.user)
            errorMessage = nil
        } catch {
            errorMessage = "Google sign-in failed: \(error.localizedDescription)"
        }
    }

    public func prepareAppleSignIn(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentAppleNonce = nonce
        errorMessage = nil
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    public func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        isBusy = true
        defer {
            isBusy = false
            currentAppleNonce = nil
        }

        do {
            let credential = try appleCredential(from: result)
            let authResult = try await Auth.auth().signIn(with: credential)
            updateCurrentUser(authResult.user)
            errorMessage = nil
        } catch HostAuthError.userCancelled {
            errorMessage = nil
        } catch {
            errorMessage = "Apple sign-in failed: \(error.localizedDescription)"
        }
    }

    public func signOut() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        registrationTask?.cancel()
        registrationTask = nil
        currentAppleNonce = nil
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
        } else {
            currentUser = nil
        }
    }

    private func appleCredential(from result: Result<ASAuthorization, Error>) throws -> OAuthCredential {
        switch result {
        case .failure(let error):
            if let appleError = error as? ASAuthorizationError, appleError.code == .canceled {
                throw HostAuthError.userCancelled
            }
            throw error
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                throw HostAuthError.missingAppleCredential
            }
            guard let nonce = currentAppleNonce else {
                throw HostAuthError.missingAppleNonce
            }
            guard let identityToken = appleIDCredential.identityToken,
                  let idTokenString = String(data: identityToken, encoding: .utf8) else {
                throw HostAuthError.missingAppleIdentityToken
            }
            return OAuthProvider.appleCredential(
                withIDToken: idTokenString,
                rawNonce: nonce,
                fullName: appleIDCredential.fullName
            )
        }
    }

    private static func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in
                var random: UInt8 = 0
                let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                if status != errSecSuccess {
                    fatalError("Unable to generate nonce. OSStatus \(status)")
                }
                return random
            }

            for random in randoms where remainingLength > 0 {
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }

        return result
    }
}

private enum HostAuthError: LocalizedError {
    case missingGoogleIDToken
    case missingAppleCredential
    case missingAppleIdentityToken
    case missingAppleNonce
    case apiUnavailable
    case notAuthenticated
    case registrationNotConfigured
    case userCancelled

    var errorDescription: String? {
        switch self {
        case .missingGoogleIDToken:
            return "Google sign-in returned no ID token."
        case .missingAppleCredential:
            return "Apple sign-in did not return a valid credential."
        case .missingAppleIdentityToken:
            return "Apple sign-in returned no identity token."
        case .missingAppleNonce:
            return "Apple sign-in nonce was missing."
        case .apiUnavailable:
            return "Host API base URL is not configured."
        case .notAuthenticated:
            return "Authentication required. Sign in and try again."
        case .registrationNotConfigured:
            return "Host registration is not configured yet."
        case .userCancelled:
            return "Apple sign-in was cancelled."
        }
    }
}

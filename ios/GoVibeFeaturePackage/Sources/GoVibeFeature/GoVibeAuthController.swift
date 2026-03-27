import AuthenticationServices
import CryptoKit
import FirebaseAuth
import GoogleSignIn
import Observation
import UIKit

public struct GoVibeAuthenticatedUser: Equatable, Sendable {
    public let uid: String
    public let email: String?
    public let displayName: String?
}

public enum GoVibeAuthBootstrapState: Sendable {
    case checking
    case authenticated
    case unauthenticated
}

@MainActor
@Observable
public final class GoVibeAuthController {
    public static let shared = GoVibeAuthController()

    public private(set) var currentUser: GoVibeAuthenticatedUser?
    public private(set) var isBusy = false
    public private(set) var hasAttemptedRestore = false
    public private(set) var bootstrapState: GoVibeAuthBootstrapState = .checking
    public var errorMessage: String?

    @ObservationIgnored
    private var authStateHandle: AuthStateDidChangeListenerHandle?
    @ObservationIgnored
    private var deviceRegistrationTask: Task<Void, Error>?
    @ObservationIgnored
    private var isRestoringSession = false
    @ObservationIgnored
    private var currentAppleNonce: String?

    public var isAuthenticated: Bool {
        currentUser != nil
    }

    public init() {
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                await self?.handleObservedAuthStateChange(user)
            }
        }
    }

    public func restoreSessionIfPossible() async {
        guard !hasAttemptedRestore else { return }
        hasAttemptedRestore = true

        if let currentUser = Auth.auth().currentUser {
            await resolveAuthenticatedUser(currentUser)
            return
        }

        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else {
            resolveUnauthenticatedUser()
            return
        }

        isRestoringSession = true
        isBusy = true
        defer {
            isBusy = false
            isRestoringSession = false
        }

        do {
            let googleUser = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            try await signInToFirebase(with: googleUser)
            errorMessage = nil
        } catch {
            errorMessage = "Google session restore failed: \(error.localizedDescription)"
            GIDSignIn.sharedInstance.signOut()
            resolveUnauthenticatedUser()
        }
    }

    public func signIn() async {
        guard let presentingViewController = Self.topViewController() else {
            errorMessage = "Unable to present Google Sign-In."
            return
        }

        GoVibeAnalytics.log("auth_method_chosen", parameters: ["method": "google"])
        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController)
            try await signInToFirebase(with: result.user)
            errorMessage = nil
            GoVibeAnalytics.log("auth_success", parameters: ["method": "google"])
        } catch {
            errorMessage = "Google sign-in failed: \(error.localizedDescription)"
            GoVibeAnalytics.log("auth_failure", parameters: ["method": "google", "error_message": error.localizedDescription])
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
        GoVibeAnalytics.log("auth_method_chosen", parameters: ["method": "apple"])
        isBusy = true
        defer {
            isBusy = false
            currentAppleNonce = nil
        }

        do {
            let credential = try appleCredential(from: result)
            let authResult = try await Auth.auth().signIn(with: credential)
            try await ensureCurrentIOSDeviceRegistered()
            await resolveAuthenticatedUser(authResult.user)
            errorMessage = nil
            GoVibeAnalytics.log("auth_success", parameters: ["method": "apple"])
        } catch AuthError.userCancelled {
            errorMessage = nil
        } catch {
            errorMessage = "Apple sign-in failed: \(error.localizedDescription)"
            GoVibeAnalytics.log("auth_failure", parameters: ["method": "apple", "error_message": error.localizedDescription])
        }
    }

    public func signOut() {
        GoVibeAnalytics.log("auth_sign_out")
        GoVibeAnalytics.setUserID(nil)
        deviceRegistrationTask?.cancel()
        deviceRegistrationTask = nil
        currentAppleNonce = nil
        do {
            try Auth.auth().signOut()
        } catch {
            errorMessage = "Sign out failed: \(error.localizedDescription)"
        }
        GIDSignIn.sharedInstance.signOut()
        resolveUnauthenticatedUser()
    }

    private func signInToFirebase(with googleUser: GIDGoogleUser) async throws {
        guard let idToken = googleUser.idToken?.tokenString else {
            throw AuthError.missingGoogleIDToken
        }

        let accessToken = googleUser.accessToken.tokenString
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        let result = try await Auth.auth().signIn(with: credential)
        try await ensureCurrentIOSDeviceRegistered()
        await resolveAuthenticatedUser(result.user)
    }

    public func ensureCurrentIOSDeviceRegistered() async throws {
        guard Auth.auth().currentUser != nil else { return }

        if let task = deviceRegistrationTask {
            try await task.value
            return
        }

        let task = Task {
            try await self.registerCurrentIOSDeviceIfPossible()
        }
        deviceRegistrationTask = task

        do {
            try await task.value
        } catch {
            deviceRegistrationTask = nil
            throw error
        }
    }

    private func registerCurrentIOSDeviceIfPossible() async throws {
        guard let apiBaseURL = AppRuntimeConfig.apiBaseURL else { return }
        let apiClient = GoVibeAPIClient(baseURL: apiBaseURL)
        try await apiClient.registerIOSDevice(deviceId: LocalDevice.iosDeviceID, displayName: UIDevice.current.name)
    }

    private func handleObservedAuthStateChange(_ user: User?) async {
        if let user {
            await resolveAuthenticatedUser(user)
            return
        }

        guard hasAttemptedRestore, !isRestoringSession else { return }
        resolveUnauthenticatedUser()
    }

    private func resolveAuthenticatedUser(_ user: User) async {
        do {
            try await ensureCurrentIOSDeviceRegistered()
            errorMessage = nil
        } catch {
            errorMessage = "iPhone registration failed: \(error.localizedDescription)"
        }
        currentUser = GoVibeAuthenticatedUser(
            uid: user.uid,
            email: user.email,
            displayName: user.displayName
        )
        bootstrapState = .authenticated
        GoVibeAnalytics.setUserID(user.uid)
        GoVibeAnalytics.setUserProperties()
    }

    private func resolveUnauthenticatedUser() {
        currentUser = nil
        bootstrapState = .unauthenticated
    }

    private static func topViewController(
        controller: UIViewController? = UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    ) -> UIViewController? {
        if let navigationController = controller as? UINavigationController {
            return topViewController(controller: navigationController.visibleViewController)
        }
        if let tabController = controller as? UITabBarController {
            return topViewController(controller: tabController.selectedViewController)
        }
        if let presented = controller?.presentedViewController {
            return topViewController(controller: presented)
        }
        return controller
    }

    private func appleCredential(from result: Result<ASAuthorization, Error>) throws -> OAuthCredential {
        switch result {
        case .failure(let error):
            if let appleError = error as? ASAuthorizationError, appleError.code == .canceled {
                throw AuthError.userCancelled
            }
            throw error
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                throw AuthError.missingAppleCredential
            }
            guard let nonce = currentAppleNonce else {
                throw AuthError.missingAppleNonce
            }
            guard let identityToken = appleIDCredential.identityToken,
                  let idTokenString = String(data: identityToken, encoding: .utf8) else {
                throw AuthError.missingAppleIdentityToken
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

private enum AuthError: LocalizedError {
    case missingGoogleIDToken
    case missingAppleCredential
    case missingAppleIdentityToken
    case missingAppleNonce
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
        case .userCancelled:
            return "Apple sign-in was cancelled."
        }
    }
}

import FirebaseAuth
import GoogleSignIn
import Observation
import UIKit

public struct GoVibeAuthenticatedUser: Equatable, Sendable {
    public let uid: String
    public let email: String?
    public let displayName: String?
}

@MainActor
@Observable
public final class GoVibeAuthController {
    public static let shared = GoVibeAuthController()

    public private(set) var currentUser: GoVibeAuthenticatedUser?
    public private(set) var isBusy = false
    public private(set) var hasAttemptedRestore = false
    public var errorMessage: String?

    @ObservationIgnored
    private var authStateHandle: AuthStateDidChangeListenerHandle?

    public var isAuthenticated: Bool {
        currentUser != nil
    }

    public init() {
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.updateCurrentUser(user)
            }
        }
        updateCurrentUser(Auth.auth().currentUser)
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
        guard let presentingViewController = Self.topViewController() else {
            errorMessage = "Unable to present Google Sign-In."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController)
            try await signInToFirebase(with: result.user)
            errorMessage = nil
        } catch {
            errorMessage = "Google sign-in failed: \(error.localizedDescription)"
        }
    }

    public func signOut() {
        do {
            try Auth.auth().signOut()
        } catch {
            errorMessage = "Sign out failed: \(error.localizedDescription)"
        }
        GIDSignIn.sharedInstance.signOut()
        updateCurrentUser(nil)
    }

    private func signInToFirebase(with googleUser: GIDGoogleUser) async throws {
        guard let idToken = googleUser.idToken?.tokenString else {
            throw AuthError.missingIDToken
        }

        let accessToken = googleUser.accessToken.tokenString
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        let result = try await Auth.auth().signIn(with: credential)
        try await registerCurrentIOSDeviceIfPossible()
        updateCurrentUser(result.user)
    }

    private func registerCurrentIOSDeviceIfPossible() async throws {
        guard let apiBaseURL = AppRuntimeConfig.apiBaseURL else { return }
        let apiClient = GoVibeAPIClient(baseURL: apiBaseURL)
        try await apiClient.registerIOSDevice(deviceId: LocalDevice.iosDeviceID, displayName: UIDevice.current.name)
    }

    private func updateCurrentUser(_ user: User?) {
        if let user {
            currentUser = GoVibeAuthenticatedUser(
                uid: user.uid,
                email: user.email,
                displayName: user.displayName
            )
        } else {
            currentUser = nil
        }
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
}

private enum AuthError: LocalizedError {
    case missingIDToken

    var errorDescription: String? {
        switch self {
        case .missingIDToken:
            return "Google sign-in returned no ID token."
        }
    }
}

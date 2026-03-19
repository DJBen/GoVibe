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
        deviceRegistrationTask?.cancel()
        deviceRegistrationTask = nil
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
            throw AuthError.missingIDToken
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

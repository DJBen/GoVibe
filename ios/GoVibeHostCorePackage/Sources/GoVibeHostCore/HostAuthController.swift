import AppKit
import FirebaseAuth
import FirebaseCore
import Foundation
import GoogleSignIn
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

    public func signOut() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
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

        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            await self.runHostRegistrationLoop(payload: payload)
        }
    }

    private func runHostRegistrationLoop(payload: HostRegistrationPayload) async {
        guard let apiClient else {
            errorMessage = "Host API base URL is not configured."
            return
        }

        do {
            try await apiClient.registerHost(payload)
            errorMessage = nil
        } catch {
            errorMessage = "Host registration failed: \(error.localizedDescription)"
            return
        }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
                try await apiClient.heartbeat(payload)
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
            throw HostAuthError.missingIDToken
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
}

private enum HostAuthError: LocalizedError {
    case missingIDToken

    var errorDescription: String? {
        switch self {
        case .missingIDToken:
            return "Google sign-in returned no ID token."
        }
    }
}

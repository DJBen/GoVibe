import SwiftUI
import Observation

enum ContentRoute: Equatable {
    case missingConfig
    case launch
    case sessions
    case signIn
}

public struct ContentView: View {
    private var config = AppConfig.shared
    private var foregroundNotifications = ForegroundNotificationCoordinator.shared
    @State private var authController = GoVibeAuthController.shared

    public var body: some View {
        Group {
            switch Self.route(configIsValid: config.isValid, bootstrapState: authController.bootstrapState) {
            case .missingConfig:
                GoVibeMissingConfigView()
            case .launch:
                GoVibeLaunchView()
            case .sessions:
                SessionListView()
            case .signIn:
                GoVibeSignInView()
            }
        }
        .overlay(alignment: .top) {
            if let banner = foregroundNotifications.banner {
                InAppNotificationBannerView(
                    banner: banner,
                    onTap: {
                        if let roomId = banner.roomId {
                            foregroundNotifications.pendingDeepLinkRoomId = roomId
                        }
                        foregroundNotifications.dismissBanner()
                    },
                    onDismiss: { foregroundNotifications.dismissBanner() }
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: foregroundNotifications.banner)
        .task {
            await authController.restoreSessionIfPossible()
        }
    }

    public init() {}

    static func route(configIsValid: Bool, bootstrapState: GoVibeAuthBootstrapState) -> ContentRoute {
        guard configIsValid else { return .missingConfig }

        switch bootstrapState {
        case .checking:
            return .launch
        case .authenticated:
            return .sessions
        case .unauthenticated:
            return .signIn
        }
    }
}

private struct GoVibeMissingConfigView: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.orange)

            VStack(spacing: 6) {
                Text("Configuration Missing")
                    .font(.title2.weight(.semibold))

                Text("GoVibe requires relay and GCP settings provided via build configuration. Please check your xcconfig or environment variables.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(24)
    }
}

private struct GoVibeLaunchView: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("GoVibe")
                    .font(.title2.weight(.semibold))

                Text("Checking your account…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ProgressView()
                .controlSize(.regular)

            Spacer()
        }
        .padding(24)
    }
}

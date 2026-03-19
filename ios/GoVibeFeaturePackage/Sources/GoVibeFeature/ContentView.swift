import SwiftUI
import Observation

public struct ContentView: View {
    private var config = AppConfig.shared
    private var foregroundNotifications = ForegroundNotificationCoordinator.shared
    @State private var authController = GoVibeAuthController.shared

    public var body: some View {
        Group {
            if config.isValid {
                if authController.isAuthenticated {
                    SessionListView()
                } else {
                    GoVibeSignInView()
                }
            } else {
                AppConfigSetupView()
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
}

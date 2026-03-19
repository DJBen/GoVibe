import FirebaseCore
import FirebaseMessaging
import UIKit
import UserNotifications

@MainActor
public final class GoVibeAppDelegate: NSObject, UIApplicationDelegate, @MainActor UNUserNotificationCenterDelegate, MessagingDelegate {

    // SessionViewModel sets this after auth to be notified of new/refreshed tokens.
    public static var onFCMTokenRefresh: (@MainActor (String) -> Void)?
    // Stores the latest token so SessionViewModel can register it after auth
    // even if the token arrived before auth was established.
    public static var latestFCMToken: String?

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        GoVibeBootstrap.configureFirebaseIfNeeded()
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        // Silent registration — required so iOS delivers the APNs token to
        // didRegisterForRemoteNotificationsWithDeviceToken, which Firebase
        // needs to exchange for an FCM token. No permission dialog is shown.
        UIApplication.shared.registerForRemoteNotifications()
        return true
    }

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
    }

    // Called by Firebase once per app launch (and on token refresh) with a valid FCM token.
    public nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        print("[GoVibe] FCM token: \(fcmToken)")
        Task { @MainActor in
            GoVibeAppDelegate.latestFCMToken = fcmToken
            GoVibeAppDelegate.onFCMTokenRefresh?(fcmToken)
        }
    }

    // Suppress system UI while foregrounded and let the active screen react in-app.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        ForegroundNotificationCoordinator.shared.handleForegroundNotification(notification)
        completionHandler([])
    }

    // Called when the user taps a system notification (app backgrounded or killed).
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        ForegroundNotificationCoordinator.shared.handleNotificationTap(userInfo: userInfo)
        completionHandler()
    }
}

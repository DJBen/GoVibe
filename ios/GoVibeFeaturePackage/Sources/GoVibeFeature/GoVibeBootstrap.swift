import FirebaseCore
import FirebaseMessaging
import Foundation
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

public enum GoVibeBootstrap {
    public static func configureFirebaseIfNeeded() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }

    #if canImport(UIKit)
    // MARK: - Notification Onboarding

    /// True once the user has dismissed the notification onboarding sheet
    /// (either "Allow" or "Not now"). Prevents showing the sheet again.
    public static var hasSeenNotificationOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "notificationOnboardingSeen") }
        set { UserDefaults.standard.set(newValue, forKey: "notificationOnboardingSeen") }
    }

    /// Trigger the real iOS system permission dialog.
    /// Called only when the user taps "Allow" in the onboarding sheet.
    public static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    public static func setAPNSToken(_ tokenData: Data) {
        Messaging.messaging().apnsToken = tokenData
    }
    #endif
}

import FirebaseCore
import FirebaseMessaging
import Foundation
import UIKit
import UserNotifications

public enum GoVibeBootstrap {
    public static func configureFirebaseIfNeeded() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }

    // MARK: - Notification Onboarding

    /// True once the user has dismissed the notification onboarding sheet
    /// (either "Allow" or "Not now"). Prevents showing the sheet again.
    public static var hasSeenNotificationOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "notificationOnboardingSeen") }
        set { UserDefaults.standard.set(newValue, forKey: "notificationOnboardingSeen") }
    }

    /// True once the user dismisses the simulator interaction mode hint banner.
    public static var hasSeenSimulatorInteractionModeHint: Bool {
        get { UserDefaults.standard.bool(forKey: "simulatorInteractionModeHintSeen") }
        set { UserDefaults.standard.set(newValue, forKey: "simulatorInteractionModeHintSeen") }
    }

    /// Trigger the real iOS system permission dialog.
    /// Called only when the user taps "Allow" in the onboarding sheet.
    public static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    public static func setAPNSToken(_ tokenData: Data) {
        Messaging.messaging().apnsToken = tokenData
    }
}

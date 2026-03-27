import FirebaseAnalytics
import Foundation

enum GoVibeAnalytics {
    // MARK: - User Properties

    static func setUserProperties() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        Analytics.setUserProperty("ios", forName: "platform")
        Analytics.setUserProperty(version, forName: "app_version")
    }

    static func setUserID(_ uid: String?) {
        Analytics.setUserID(uid)
    }

    // MARK: - Screen Views

    static func logScreenView(_ name: String) {
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: name,
            AnalyticsParameterScreenClass: name,
        ])
    }

    // MARK: - Events

    static func log(_ event: String, parameters: [String: Any]? = nil) {
        Analytics.logEvent(event, parameters: parameters)
    }
}

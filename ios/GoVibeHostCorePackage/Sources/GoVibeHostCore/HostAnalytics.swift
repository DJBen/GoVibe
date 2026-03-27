import FirebaseAnalytics
import Foundation

public enum HostAnalytics {
    // MARK: - User Properties

    public static func setUserProperties() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        Analytics.setUserProperty("macos", forName: "platform")
        Analytics.setUserProperty(version, forName: "app_version")
    }

    public static func setUserID(_ uid: String?) {
        Analytics.setUserID(uid)
    }

    // MARK: - Screen Views

    public static func logScreenView(_ name: String) {
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: name,
            AnalyticsParameterScreenClass: name,
        ])
    }

    // MARK: - Events

    public static func log(_ event: String, parameters: [String: Any]? = nil) {
        Analytics.logEvent(event, parameters: parameters)
    }
}

import Foundation

@MainActor
enum AppRuntimeConfig {
    static var apiBaseURL: URL? {
        AppConfig.shared.apiBaseURL
    }

    static var relayWebSocketBase: String {
        AppConfig.shared.relayWebSocketBase ?? ""
    }
}

import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class ForegroundNotificationCoordinator {
    static let shared = ForegroundNotificationCoordinator()

    var activeRoomId: String?
    var banner: InAppNotificationBanner?
    /// Set when the user taps a system notification while the app is backgrounded or killed.
    /// `SessionListView` consumes this once to perform deep-link navigation.
    var pendingDeepLinkRoomId: String?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func setActiveRoomId(_ roomId: String?) {
        activeRoomId = roomId
        guard banner?.roomId == roomId else { return }
        dismissBanner()
    }

    func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        let payload = ForegroundNotificationPayload(userInfo: userInfo, title: nil, body: nil)
        guard let roomId = payload.roomId else { return }
        pendingDeepLinkRoomId = roomId
    }

    func handleForegroundNotification(_ notification: UNNotification) {
        let payload = ForegroundNotificationPayload(notification: notification)
        guard payload.roomId != activeRoomId else {
            dismissBanner()
            return
        }

        showBanner(
            InAppNotificationBanner(
                title: payload.title,
                body: payload.body,
                roomId: payload.roomId,
                event: payload.event
            )
        )
    }

    func dismissBanner() {
        dismissTask?.cancel()
        dismissTask = nil
        banner = nil
    }

    private func showBanner(_ banner: InAppNotificationBanner) {
        dismissTask?.cancel()
        self.banner = banner

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.banner = nil
            self?.dismissTask = nil
        }
    }
}

struct InAppNotificationBanner: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let body: String
    let roomId: String?
    let event: String?
}

struct ForegroundNotificationPayload {
    let title: String
    let body: String
    let roomId: String?
    let event: String?

    init(notification: UNNotification) {
        let content = notification.request.content
        self.init(
            userInfo: content.userInfo,
            title: content.title,
            body: content.body
        )
    }

    init(userInfo: [AnyHashable: Any], title: String?, body: String?) {
        let event = userInfo["event"] as? String
        let resolvedTitle = Self.nonEmpty(title) ?? Self.defaultTitle(for: event)
        let resolvedBody = Self.nonEmpty(body) ?? Self.defaultBody(for: event)

        self.title = resolvedTitle
        self.body = resolvedBody
        self.roomId = Self.nonEmpty(userInfo["roomId"] as? String)
            ?? Self.nonEmpty(userInfo["room"] as? String)
            ?? Self.nonEmpty(userInfo["sessionId"] as? String)
        self.event = event
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func defaultTitle(for event: String?) -> String {
        let assistant = assistantName(for: event)
        switch event {
        case "claude_approval_required", "codex_approval_required":
            return "Unblock \(assistant) now"
        case "claude_turn_complete", "codex_turn_complete":
            return "\(assistant) finished"
        default:
            return "\(assistant) update"
        }
    }

    private static func defaultBody(for event: String?) -> String {
        let assistant = assistantName(for: event)
        switch event {
        case "claude_approval_required", "codex_approval_required":
            return "\(assistant) requires your decision before proceeding"
        case "claude_turn_complete", "codex_turn_complete":
            return "\(assistant) is waiting for your next prompt."
        default:
            return "\(assistant) is waiting for your input."
        }
    }

    private static func assistantName(for event: String?) -> String {
        if event?.starts(with: "codex_") == true {
            return "Codex"
        }
        return "Claude"
    }
}

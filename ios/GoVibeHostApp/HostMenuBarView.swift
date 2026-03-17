import SwiftUI
import GoVibeHostCore
import AppKit

struct HostMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @State var manager: HostSessionManager
    private let relativeDateFormatter = RelativeDateTimeFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Button("Open GoVibe Host") {
                    presentMainWindow()
                }
                .buttonStyle(.plain)

                Button("Show Host ID") {
                    presentHostIDWindow()
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            sessionSummary
                .frame(maxWidth: .infinity)

            Divider()

            Button("Quit app") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder
    private var sessionSummary: some View {
        let activeCount = manager.listSessions()
            .filter { $0.state == .running || $0.state == .waitingForPeer || $0.state == .stale }
            .count

        VStack(spacing: 10) {
            Text("\(activeCount) hosted sessions")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if manager.listSessions().isEmpty {
                Text("No hosted relay sessions yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ForEach(manager.listSessions()) { session in
                    VStack(spacing: 2) {
                        Text(session.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.caption)

                        Text("\(session.kind.rawValue.capitalized) • \(stateLabel(for: session))")
                            .font(.caption2)
                            .foregroundStyle(stateColor(for: session.state))
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .multilineTextAlignment(.center)
    }

    private func presentHostIDWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "host-id")

        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "host-id" || $0.title == "Host ID" }) else { return }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func presentMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")

        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.title == "GoVibe Host" }) else { return }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func stateLabel(for session: HostedSessionDescriptor) -> String {
        switch session.state {
        case .waitingForPeer:
            return "Waiting"
        case .stale:
            if let lastPeerActivityAt = session.lastPeerActivityAt {
                return "Last active \(relativeDateFormatter.localizedString(for: lastPeerActivityAt, relativeTo: .now))"
            }
            return "Last active a while ago"
        default:
            return session.state.displayLabel
        }
    }

    private func stateColor(for state: HostedSessionState) -> Color {
        switch state {
        case .running:
            .green
        case .waitingForPeer, .starting:
            .orange
        case .stale, .error:
            .red
        case .stopped:
            .secondary
        }
    }
}

import SwiftUI
import GoVibeHostCore
import AppKit

struct HostMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @State var manager: HostSessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GoVibe Host")
                .font(.headline)

            Text("\(manager.listSessions().filter { $0.state == .running || $0.state == .waitingForPeer || $0.state == .stale }.count) hosted sessions")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if manager.listSessions().isEmpty {
                Text("No hosted relay sessions yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.listSessions()) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.caption)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(session.kind.rawValue.capitalized) • \(stateLabel(for: session.state))")
                                .font(.caption2)
                                .foregroundStyle(stateColor(for: session.state))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Button("Open GoVibe Host") {
                    presentMainWindow()
                }
                .buttonStyle(.plain)

                Button("Quit GoVibe Host") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 300)
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

    private func stateLabel(for state: HostedSessionState) -> String {
        switch state {
        case .waitingForPeer:
            "Waiting"
        default:
            state.rawValue.capitalized
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

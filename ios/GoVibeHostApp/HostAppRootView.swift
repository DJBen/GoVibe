import SwiftUI
import GoVibeHostCore

struct HostAppRootView: View {
    @State var manager: HostSessionManager

    var body: some View {
        Group {
            if manager.settings.onboardingCompleted {
                HostDashboardView(manager: manager)
            } else {
                HostOnboardingView(manager: manager)
            }
        }
        .task {
            manager.refreshEnvironment()
        }
    }
}

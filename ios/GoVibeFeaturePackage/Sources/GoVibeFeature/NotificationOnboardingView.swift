import SwiftUI

struct NotificationOnboardingView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            mockNotificationBanner
                .padding(.top, 32)

            VStack(spacing: 12) {
                Text("Know when Claude is done")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("GoVibe can send you a notification when Claude or Codex finishes processing so you don't have to keep checking.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    GoVibeBootstrap.hasSeenNotificationOnboarding = true
                    GoVibeBootstrap.requestNotificationPermission()
                    onDismiss()
                } label: {
                    Text("Allow Notifications")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    GoVibeBootstrap.hasSeenNotificationOnboarding = true
                    onDismiss()
                } label: {
                    Text("Not now")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
    }

    private var mockNotificationBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "app.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("GoVibe")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Text("now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Claude finished")
                    .font(.footnote.weight(.semibold))
                Text("Claude is waiting for your next prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        )
    }
}

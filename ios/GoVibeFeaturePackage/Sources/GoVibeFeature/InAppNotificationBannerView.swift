import SwiftUI

struct InAppNotificationBannerView: View {
    let banner: InAppNotificationBanner
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image("AppNotificationIcon")
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(banner.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification banner")
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 10)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { onTap() }
        .accessibilityIdentifier("foreground_notification_banner")
    }
}

#Preview("In-App Notification Banner") {
    ZStack(alignment: .top) {
        LinearGradient(
            colors: [Color(red: 0.94, green: 0.95, blue: 0.97), Color(red: 0.84, green: 0.88, blue: 0.93)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        InAppNotificationBannerView(
            banner: InAppNotificationBanner(
                title: "Claude finished",
                body: "Claude is waiting for your next prompt.",
                roomId: "ios-dev",
                event: "claude_turn_complete"
            ),
            onTap: {},
            onDismiss: {}
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

import SwiftUI

struct GoVibeSignInView: View {
    @State private var authController = GoVibeAuthController.shared

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 54))
                .foregroundStyle(.tint)

            Text("Sign In Required")
                .font(.title2.bold())

            Text("Sign in with Google to discover and open the Mac hosts owned by your account.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if let errorMessage = authController.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button {
                Task { await authController.signIn() }
            } label: {
                ZStack {
                    Image("ContinueWithGoogle", bundle: .main)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(authController.isBusy ? 0.7 : 1)

                    if authController.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 240)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(authController.isBusy)

            Spacer()
        }
        .padding(24)
    }
}

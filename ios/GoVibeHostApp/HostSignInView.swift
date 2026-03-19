import GoVibeHostCore
import SwiftUI

struct HostSignInView: View {
    @State var auth: HostAuthController

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "desktopcomputer.and.macbook")
                .font(.system(size: 54))
                .foregroundStyle(.tint)

            Text("Sign In Required")
                .font(.largeTitle.bold())

            Text("Sign in with Google so this Mac host is tied to your Firebase account and only discovered by your devices.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if let errorMessage = auth.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button {
                Task { await auth.signIn() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                    Text(auth.isBusy ? "Signing In..." : "Continue With Google")
                        .fontWeight(.semibold)
                }
                .frame(width: 280)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(auth.isBusy)

            Spacer()
        }
        .padding(32)
    }
}

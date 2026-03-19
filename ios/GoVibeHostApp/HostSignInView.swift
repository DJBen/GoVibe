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

            Text("Sign in to make Claude, Codex and Gemini CLI available to your phone. Vibe code anywhere you go.")
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
                ZStack {
                    Image("ContinueWithGoogle")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .opacity(auth.isBusy ? 0.7 : 1)

                    if auth.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 240)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(auth.isBusy)

            Spacer()
        }
        .padding(32)
    }
}

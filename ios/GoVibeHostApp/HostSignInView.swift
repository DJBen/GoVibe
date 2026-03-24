import AuthenticationServices
import GoVibeHostCore
import SwiftUI

private struct UniformPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

struct HostSignInView: View {
    @State var auth: HostAuthController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "desktopcomputer.and.macbook")
                .font(.system(size: 54))
                .foregroundStyle(.tint)

            Text("Sign In Required")
                .font(.largeTitle.bold())

            Text("Sign in with Google or Apple to make Claude, Codex and Gemini CLI available to your phone. Vibe code anywhere you go.")
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

            if auth.isBusy {
                ProgressView().controlSize(.extraLarge)
            } else {
                VStack(spacing: 12) {
                    Button {
                        Task { await auth.signIn() }
                    } label: {
                        Color("GoogleBackgroundColor").overlay {
                            Image("ContinueWithGoogle")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .opacity(auth.isBusy ? 0.7 : 1)
                        }
                        .frame(width: 240, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .compositingGroup()
                    }
                    .buttonStyle(UniformPressButtonStyle())

                    SignInWithAppleButton(.continue) { request in
                        auth.prepareAppleSignIn(request)
                    } onCompletion: { result in
                        Task { await auth.completeAppleSignIn(result) }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(width: 240)
                }
            }

            Spacer()
        }
        .padding(32)
    }
}

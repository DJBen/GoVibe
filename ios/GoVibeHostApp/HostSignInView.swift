import AuthenticationServices
import GoVibeHostCore
import SwiftUI

private struct UniformPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

private struct ScrollingTitleView: View {
    private let tools = ["Claude", "Codex", "Gemini"]
    private let toolColors: [Color] = [
        Color(red: 0.85, green: 0.45, blue: 0.25),
        Color(red: 0.25, green: 0.75, blue: 0.55),
        Color(red: 0.35, green: 0.50, blue: 0.95),
    ]
    @State private var currentIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Vibe code with")
                .font(.system(size: 42, weight: .bold))
            Text(tools[currentIndex])
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(toolColors[currentIndex])
                .transition(.push(from: .bottom))
                .id(currentIndex)
            Text("on the go")
                .font(.system(size: 42, weight: .bold))
        }
        .onAppear {
            startCycling()
        }
    }

    private func startCycling() {
        withAnimation(.smooth(duration: 0.4)) {
            currentIndex = (currentIndex + 1) % tools.count
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            startCycling()
        }
    }
}

struct HostSignInView: View {
    @State var auth: HostAuthController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 20) {
            ScrollingTitleView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 40)

            Spacer()

            Text("Sign in with Google or Apple to make Claude, Codex and Gemini CLI available to your phone.")
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
                        HStack(spacing: 4) {
                            Image("GoogleSymbol")
                                .renderingMode(.original)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 12, height: 12)
                            Text("Continue with Google")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(colorScheme == .dark ? .black : .white)
                        }
                        .frame(width: 240, height: 32)
                        .background(colorScheme == .dark ? Color.white : Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        }
        .padding(40)
        .padding(.bottom, 20)
    }
}

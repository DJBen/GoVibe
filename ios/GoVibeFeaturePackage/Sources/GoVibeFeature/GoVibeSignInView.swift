import AuthenticationServices
import SwiftUI

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
                .font(.system(size: 38, weight: .bold))
            Text(tools[currentIndex])
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(toolColors[currentIndex])
                .transition(.push(from: .bottom))
                .id(currentIndex)
            Text("on the go")
                .font(.system(size: 38, weight: .bold))
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

struct GoVibeSignInView: View {
    @State private var authController = GoVibeAuthController.shared
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 0) {
            ScrollingTitleView()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 80)

            Spacer()

            // Sign-in section
            VStack(spacing: 16) {
                if let errorMessage = authController.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await authController.signIn() }
                    } label: {
                        HStack(spacing: 6) {
                            Image("GoogleSymbol", bundle: .main)
                                .renderingMode(.original)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                            Text("Continue with Google")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(colorScheme == .dark ? .black : .white)
                        }
                        .frame(width: 240, height: 56)
                        .background(colorScheme == .dark ? Color.white : Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .opacity(authController.isBusy ? 0.7 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(authController.isBusy)

                    SignInWithAppleButton(.continue) { request in
                        authController.prepareAppleSignIn(request)
                    } onCompletion: { result in
                        Task { await authController.completeAppleSignIn(result) }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(width: 240, height: 56)
                    .disabled(authController.isBusy)
                }
            }
            .padding(.bottom, 60)
        }
        .onAppear { GoVibeAnalytics.logScreenView("sign_in") }
    }
}

import AuthenticationServices
import SwiftUI

struct GoVibeSignInView: View {
    @State private var authController = GoVibeAuthController.shared
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 0) {
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

            Spacer()
                .frame(height: 48)
        }
    }
}

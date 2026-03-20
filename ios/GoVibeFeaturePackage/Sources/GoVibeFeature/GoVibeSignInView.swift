import AuthenticationServices
import SwiftUI

struct GoVibeSignInView: View {
    @State private var authController = GoVibeAuthController.shared
    @Environment(\.colorScheme) private var colorScheme
    private let hostDownloadURL = URL(string: "https://govibe-783119.web.app")!

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    Image("HostAppIcon")
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Image(systemName: "chevron.forward.2")
                        .font(.system(size: 16))
                        .foregroundStyle(.tint)

                    Image(systemName: "macbook")
                        .font(.system(size: 32))
                        .foregroundStyle(.tint)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Get GoVibe Host on your macOS to get started")
                        .font(.body.weight(.semibold))

                    HStack(spacing: 12) {
                        Link(destination: hostDownloadURL) {
                            Label("Open", systemImage: "globe")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)

                        ShareLink(item: hostDownloadURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
            }
            .padding(16)

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
                        .frame(width: 240, height: 56)
                        .contentShape(Rectangle())
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

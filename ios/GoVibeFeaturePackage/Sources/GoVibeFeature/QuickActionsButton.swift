import SwiftUI

struct QuickActionsButton: View {
    let paneProgram: String
    var artifactCount: Int = 0
    let onSend: (Data) -> Void
    var onViewArtifacts: (() -> Void)? = nil

    @State private var showingActions = false

    private var actions: [QuickAction] {
        QuickAction.actions(for: paneProgram)
    }

    @ViewBuilder
    private var buttonIconView: some View {
        if paneProgram == "Codex" {
            Image("OpenAISymbol")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(.black)
                .padding(10)
        } else if paneProgram == "Gemini" {
            Image("GeminiSymbol")
                .resizable()
                .renderingMode(.original)
                .padding(10)
        } else {
            Image("ClaudeSymbol")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(.white)
                .padding(10)
        }
    }

    private var buttonBackground: Color {
        switch paneProgram {
        case "Codex":  return .white
        case "Gemini": return .white
        default:       return Color("ClaudeColor")
        }
    }

    var body: some View {
        if !actions.isEmpty || artifactCount > 0 {
            Button {
                showingActions = true
            } label: {
                buttonIconView
                    .frame(width: 40, height: 40)
                    .background(buttonBackground)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            }
            .confirmationDialog(paneProgram, isPresented: $showingActions, titleVisibility: .visible) {
                ForEach(actions) { action in
                    Button(role: action.isDestructive ? .destructive : nil) {
                        GoVibeAnalytics.log("quick_action_used", parameters: ["pane_program": paneProgram, "action": action.title])
                        for payload in action.payloads {
                            onSend(payload)
                        }
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
                if artifactCount > 0 {
                    Button {
                        GoVibeAnalytics.log("artifacts_viewed", parameters: [
                            "pane_program": paneProgram,
                            "count": "\(artifactCount)",
                        ])
                        onViewArtifacts?()
                    } label: {
                        Label(
                            "View \(artifactCount) artifact\(artifactCount == 1 ? "" : "s")",
                            systemImage: "doc.on.doc"
                        )
                    }
                }
            }
            .accessibilityIdentifier("quick_actions_button")
        }
    }
}

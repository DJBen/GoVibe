import SwiftUI

struct QuickActionsButton: View {
    let paneProgram: String
    let onSend: (Data) -> Void

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
        if !actions.isEmpty {
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
                        for payload in action.payloads {
                            onSend(payload)
                        }
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
            }
            .accessibilityIdentifier("quick_actions_button")
        }
    }
}

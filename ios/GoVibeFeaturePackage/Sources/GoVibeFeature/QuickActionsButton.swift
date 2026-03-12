import SwiftUI

struct QuickActionsButton: View {
    let paneProgram: String
    let onSend: (Data) -> Void

    @State private var showingActions = false

    private var actions: [QuickAction] {
        QuickAction.actions(for: paneProgram)
    }

    var body: some View {
        if !actions.isEmpty {
            Button {
                showingActions = true
            } label: {
                Image("ClaudeSymbol")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(width: 40, height: 40)
                    .background(Color("ClaudeColor"))
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

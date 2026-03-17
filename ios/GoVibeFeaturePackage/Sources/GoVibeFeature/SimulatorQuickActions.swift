#if canImport(UIKit)
import SwiftUI

struct SimulatorQuickActionsMenu: View {
    let onAction: (String) -> Void

    var body: some View {
        Menu {
            Button {
                onAction("home")
            } label: {
                Label("Home", systemImage: "house")
            }
            Button {
                onAction("shake")
            } label: {
                Label("Shake", systemImage: "iphone.radiowaves.left.and.right")
            }
            Button {
                onAction("rotateLeft")
            } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            Button {
                onAction("rotateRight")
            } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
        } label: {
            Image(systemName: "gamecontroller")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35))
                .clipShape(Circle())
        }
        .accessibilityIdentifier("sim_quick_actions_menu")
    }
}
#endif

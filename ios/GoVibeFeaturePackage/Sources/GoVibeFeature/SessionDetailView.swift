import SwiftUI

struct SessionDetailView: View {
    enum PresentationMode {
        case compact
        case regular
    }

    let roomId: String
    let presentationMode: PresentationMode
    let onExit: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SessionViewModel

    init(
        roomId: String,
        presentationMode: PresentationMode = .compact,
        onExit: (() -> Void)? = nil
    ) {
        self.roomId = roomId
        self.presentationMode = presentationMode
        self.onExit = onExit
        _viewModel = State(initialValue: SessionViewModel(macDeviceId: roomId))
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            #if canImport(UIKit)
            TerminalSurfaceView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .safeAreaPadding(.bottom, 14)
                .accessibilityIdentifier("terminal_log_view")
            #else
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.logs) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(.black.opacity(0.9))
            .foregroundStyle(.green)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("terminal_log_view")
            #endif
        }
        .overlay(alignment: .topTrailing) {
            if presentationMode == .compact && !viewModel.isInTmuxScrollMode {
                floatingInfoMenu
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let paneProgram = viewModel.paneProgram {
                QuickActionsButton(paneProgram: paneProgram) { data in
                    viewModel.sendInputDataAsync(data)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
        }
        .navigationTitle(roomId)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentationMode == .regular {
                ToolbarItem(placement: .topBarTrailing) {
                    sessionMenu
                        .accessibilityIdentifier("session_info_toolbar_menu")
                }
            }
        }
#if canImport(UIKit)
        .toolbar(presentationMode == .compact ? .hidden : .automatic, for: .navigationBar)
#endif
        .background(Color.black)
        .accessibilityIdentifier("govibe_root_view")
        .task {
            viewModel.connectRelayNow()
        }
        .onDisappear {
            viewModel.disconnectRelay()
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        HStack {
            Text("Relay: \(viewModel.relayStatus)")
                .font(.caption)
                .foregroundStyle(.white)
                .accessibilityIdentifier("relay_status_text")
            Spacer()
            if viewModel.isInTmuxScrollMode {
                Button {
                    viewModel.sendScrollCancelAsync()
                } label: {
                    Label("Exit Scroll", systemImage: "escape")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.yellow)
                        .clipShape(Capsule())
                }
                .accessibilityIdentifier("exit_scroll_button")
            } else {
                Text(viewModel.paneProgram ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(viewModel.paneProgram != nil ? .green : .white.opacity(0.4))
                    .accessibilityIdentifier("pane_program_text")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black)
    }

    private var sessionMenu: some View {
        Menu {
            Button {
                viewModel.forceResizeSync()
            } label: {
                Label("Force Resize", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            #if DEBUG
            Button {
                viewModel.debugDisconnectAndReconnectRelay()
            } label: {
                Label("Debug: Reconnect Relay", systemImage: "arrow.clockwise.circle")
            }
            #endif
            Button(role: .destructive) {
                exitSession()
            } label: {
                Label("Exit Session", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(presentationMode == .compact ? 10 : 0)
                .background(presentationMode == .compact ? .black.opacity(0.35) : .clear)
                .clipShape(Circle())
        }
        .accessibilityIdentifier("session_info_menu")
    }

    private var floatingInfoMenu: some View {
        sessionMenu
            .padding(.top, 12)
            .padding(.trailing, 12)
    }

    private func exitSession() {
        viewModel.disconnectRelay()
        if let onExit {
            onExit()
        } else {
            dismiss()
        }
    }
}

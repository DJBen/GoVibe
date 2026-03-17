import SwiftUI

struct SessionDetailView: View {
    enum PresentationMode {
        case compact
        case regular
    }

    let roomId: String
    let presentationMode: PresentationMode
    let onExit: (() -> Void)?
    var onKindDiscovered: ((SessionKind) -> Void)? = nil
    var onStatusChanged: ((String) -> Void)? = nil
    #if canImport(UIKit)
    var onSnapshot: ((UIImage, Date) -> Void)? = nil
    #endif
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SessionViewModel
    @State private var showNotificationOnboarding = false
    @State private var showPlanSheet = false

    init(
        roomId: String,
        presentationMode: PresentationMode = .compact,
        onExit: (() -> Void)? = nil,
        onKindDiscovered: ((SessionKind) -> Void)? = nil,
        onStatusChanged: ((String) -> Void)? = nil
    ) {
        self.roomId = roomId
        self.presentationMode = presentationMode
        self.onExit = onExit
        self.onKindDiscovered = onKindDiscovered
        self.onStatusChanged = onStatusChanged
        _viewModel = State(initialValue: SessionViewModel(macDeviceId: roomId))
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            #if canImport(UIKit)
            if viewModel.simInfo != nil {
                SimulatorView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .accessibilityIdentifier("simulator_surface_view")
            } else {
                TerminalSurfaceView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .safeAreaPadding(.bottom, 14)
                    .accessibilityIdentifier("terminal_log_view")
            }
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
                floatingTopControls
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if viewModel.simInfo == nil, let paneProgram = viewModel.paneProgram {
                QuickActionsButton(paneProgram: paneProgram) { data in
                    viewModel.sendInputDataAsync(data)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .bottom) {
            if shouldShowPlanButton {
                viewPlanButton
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
#if canImport(UIKit)
        .onChange(of: viewModel.paneProgram) { _, newProgram in
            guard let program = newProgram,
                  (program == "Claude" || program == "Codex"),
                  viewModel.relayStatus == "Connected",
                  !GoVibeBootstrap.hasSeenNotificationOnboarding,
                  !showNotificationOnboarding else { return }
            showNotificationOnboarding = true
        }
        .sheet(isPresented: $showNotificationOnboarding) {
            NotificationOnboardingView {
                showNotificationOnboarding = false
            }
            .presentationDetents([.medium])
        }
        .fullScreenCover(isPresented: $showPlanSheet) {
            if let planState = viewModel.planState {
                PlanMarkdownSheet(plan: planState)
            }
        }
#endif
        .onChange(of: viewModel.relayStatus) { _, newStatus in
            onStatusChanged?(newStatus)
        }
        .onChange(of: viewModel.planState) { _, newValue in
            if newValue == nil {
                showPlanSheet = false
            }
        }
        .onChange(of: viewModel.simInfo) { _, simInfo in
            if simInfo != nil { onKindDiscovered?(.simulator) }
        }
        .onChange(of: viewModel.paneProgram) { _, program in
            if program != nil { onKindDiscovered?(.terminal) }
        }
        .task {
            await viewModel.bootstrapAuth()
        }
        .onDisappear {
            #if canImport(UIKit)
            // Prefer pendingSnapshotImage (captured eagerly in exitSession before
            // disconnectRelay clears simInfo and causes TerminalSurfaceView.makeUIView
            // to overwrite captureSnapshot with a blank terminal capture).
            // Fall back to captureSnapshot for the swipe-back case where exitSession
            // was never called and pendingSnapshotImage is nil.
            let image = viewModel.pendingSnapshotImage ?? viewModel.captureSnapshot?()
            if let image {
                onSnapshot?(image, Date())
            }
            viewModel.pendingSnapshotImage = nil
            #endif
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
            } else if let simInfo = viewModel.simInfo {
                Text(simInfo.deviceName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("sim_device_name_text")
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
            if presentationMode == .compact {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.35))
                    .clipShape(Circle())
            } else {
                Image(systemName: "info.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .accessibilityIdentifier("session_info_menu")
    }

    private var floatingTopControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            sessionMenu
            #if canImport(UIKit)
            if viewModel.simInfo != nil {
                SimulatorQuickActionsMenu { action in
                    viewModel.sendSimButtonAsync(action: action)
                }
            }
            #endif
            #if !canImport(UIKit)
            if let paneProgram = viewModel.paneProgram {
                QuickActionsButton(paneProgram: paneProgram) { data in
                    viewModel.sendInputDataAsync(data)
                }
            }
            #endif
        }
        .padding(.top, 12)
        .padding(.trailing, 12)
    }

    private var shouldShowPlanButton: Bool {
        viewModel.simInfo == nil &&
        !viewModel.isInTmuxScrollMode &&
        viewModel.planState != nil &&
        (viewModel.paneProgram == "Claude" || viewModel.paneProgram == "Codex")
    }

    private var viewPlanButton: some View {
        Button {
            showPlanSheet = true
        } label: {
            Label("View Plan", systemImage: "doc.text")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.black.opacity(0.78))
                .overlay {
                    Capsule()
                        .strokeBorder(.white.opacity(0.16))
                }
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("view_plan_button")
    }

    private func exitSession() {
        #if canImport(UIKit)
        if viewModel.pendingSnapshotImage == nil, let captured = viewModel.captureSnapshot?() {
            viewModel.pendingSnapshotImage = captured
        }
        #endif
        viewModel.disconnectRelay()
        if let onExit {
            onExit()
        } else {
            dismiss()
        }
    }
}

#if canImport(UIKit)
extension SessionDetailView {
    func withSnapshot(_ handler: @escaping (UIImage, Date) -> Void) -> SessionDetailView {
        var copy = self
        copy.onSnapshot = handler
        return copy
    }
}
#endif

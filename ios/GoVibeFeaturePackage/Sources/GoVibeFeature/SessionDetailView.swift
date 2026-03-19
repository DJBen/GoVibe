import SwiftUI
import UIKit

struct SessionDetailView: View {
    enum PresentationMode {
        case compact
        case regular
    }

    let session: SavedSession
    let presentationMode: PresentationMode
    let onExit: (() -> Void)?
    var onKindDiscovered: ((SessionKind) -> Void)? = nil
    var onStatusChanged: ((String) -> Void)? = nil
    var onSnapshot: ((UIImage, Date) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SessionViewModel
    @State private var showNotificationOnboarding = false
    @State private var showPlanSheet = false
    @State private var foregroundNotifications = ForegroundNotificationCoordinator.shared

    init(
        session: SavedSession,
        presentationMode: PresentationMode = .compact,
        onExit: (() -> Void)? = nil,
        onKindDiscovered: ((SessionKind) -> Void)? = nil,
        onStatusChanged: ((String) -> Void)? = nil
    ) {
        self.session = session
        self.presentationMode = presentationMode
        self.onExit = onExit
        self.onKindDiscovered = onKindDiscovered
        self.onStatusChanged = onStatusChanged
        _viewModel = State(initialValue: SessionViewModel(roomId: session.roomId, hostId: session.hostId))
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            if viewModel.simInfo != nil || viewModel.appWindowInfo != nil {
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
        }
        .overlay(alignment: .topTrailing) {
            if presentationMode == .compact && !viewModel.isInTmuxScrollMode {
                floatingTopControls
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if viewModel.simInfo == nil, viewModel.appWindowInfo == nil, let paneProgram = viewModel.paneProgram {
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
        .navigationTitle(session.roomId)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentationMode == .regular {
                ToolbarItem(placement: .topBarTrailing) {
                    sessionMenu
                        .accessibilityIdentifier("session_info_toolbar_menu")
                }
            }
        }
        .toolbar(presentationMode == .compact ? .hidden : .automatic, for: .navigationBar)
        .background(Color.black)
        .accessibilityIdentifier("govibe_root_view")
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
        .onChange(of: foregroundNotifications.pendingDeepLinkRoomId) { _, newRoomId in
            guard let newRoomId, newRoomId != session.roomId else { return }
            exitSession()
        }
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
        .onChange(of: viewModel.appWindowInfo) { _, appWindowInfo in
            if appWindowInfo != nil { onKindDiscovered?(.appWindow) }
        }
        .onChange(of: viewModel.paneProgram) { _, program in
            if program != nil { onKindDiscovered?(.terminal) }
        }
        .task {
            await viewModel.bootstrapAuth()
        }
        .onDisappear {
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
            } else if let appWindowInfo = viewModel.appWindowInfo {
                Text("\(appWindowInfo.appName) \u{2013} \(appWindowInfo.windowTitle)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .accessibilityIdentifier("app_window_name_text")
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
            if viewModel.simInfo != nil {
                SimulatorQuickActionsMenu { action in
                    viewModel.sendSimButtonAsync(action: action)
                }
            }
        }
        .padding(.top, 12)
        .padding(.trailing, 12)
    }

    private var shouldShowPlanButton: Bool {
        viewModel.simInfo == nil &&
        viewModel.appWindowInfo == nil &&
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
        if viewModel.pendingSnapshotImage == nil, let captured = viewModel.captureSnapshot?() {
            viewModel.pendingSnapshotImage = captured
        }
        viewModel.disconnectRelay()
        if let onExit {
            onExit()
        } else {
            dismiss()
        }
    }
}

extension SessionDetailView {
    func withSnapshot(_ handler: @escaping (UIImage, Date) -> Void) -> SessionDetailView {
        var copy = self
        copy.onSnapshot = handler
        return copy
    }
}

import SwiftUI
import UIKit

struct SessionListView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var store = SessionStore()
    @State private var authController = GoVibeAuthController.shared
    @State private var foregroundNotifications = ForegroundNotificationCoordinator.shared
    @State private var selectedSession: SavedSession?
    @State private var navigationPath: [SavedSession] = []
    @State private var createSessionForHost: HostInfo?
    @State private var userDeletingIds: Set<String> = []
    @State private var externallyDeletedRoomId: String? = nil
    @State private var sessionPendingDeletion: SavedSession?

    var body: some View {
        Group {
            if usesSplitView {
                NavigationSplitView {
                    sidebarContent()
                } detail: {
                    if let selectedSession {
                        SessionDetailView(
                            session: selectedSession,
                            presentationMode: .regular,
                            onExit: { self.selectedSession = nil },
                            onKindDiscovered: { kind in store.update(roomId: selectedSession.roomId, kind: kind) },
                            )
                        .withSnapshot { image, date in
                            saveSnapshot(image: image, date: date, roomId: selectedSession.roomId)
                        }
                        .id(selectedSession.roomId)
                    } else {
                        SessionPlaceholderView()
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .accessibilityIdentifier("session_split_view")
            } else {
                NavigationStack(path: $navigationPath) {
                    sidebarContent()
                        .navigationDestination(for: SavedSession.self) { session in
                            SessionDetailView(
                                session: session,
                                presentationMode: .compact,
                                onKindDiscovered: { kind in store.update(roomId: session.roomId, kind: kind) },
                            )
                            .withSnapshot { image, date in
                                saveSnapshot(image: image, date: date, roomId: session.roomId)
                            }
                        }
                }
            }
        }
        .sheet(item: $createSessionForHost) { host in
            SessionCreateView(host: host, store: store)
        }
        .accessibilityIdentifier("session_list_view")
        .onAppear { GoVibeAnalytics.logScreenView("session_list") }
        .task {
            await store.refresh()
            consumePendingDeepLink()
            syncActiveRoomSelection()
        }
        .onAppear {
            Task { await store.refresh() }
        }
        .onChange(of: foregroundNotifications.pendingDeepLinkRoomId) { _, _ in
            // Only navigate directly when no detail view is pushed.
            // When a detail view is active, SessionDetailView.onChange handles the exit
            // and onChange(of: navigationPath) handles the subsequent navigation.
            guard navigationPath.isEmpty else { return }
            consumePendingDeepLink()
        }
        .onChange(of: store.sessions) { _, sessions in
            let sessionIds = Set(sessions.map(\.roomId))

            // Detect external deletion of the currently displayed session.
            let activeRoomId = selectedSession?.roomId ?? navigationPath.last?.roomId
            if let roomId = activeRoomId,
               !sessionIds.contains(roomId),
               !userDeletingIds.contains(roomId) {
                externallyDeletedRoomId = roomId
            }

            if let selectedSession, !sessionIds.contains(selectedSession.roomId) {
                self.selectedSession = nil
            }
            navigationPath.removeAll { !sessionIds.contains($0.roomId) }
            syncActiveRoomSelection()
        }
        .alert("Session Deleted", isPresented: Binding(
            get: { externallyDeletedRoomId != nil },
            set: { if !$0 { externallyDeletedRoomId = nil } }
        )) {
            Button("OK") { externallyDeletedRoomId = nil }
        } message: {
            if let roomId = externallyDeletedRoomId {
                Text("\"\(roomId)\" was deleted by the host.")
            }
        }
        .confirmationDialog(
            "Remove Session",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let session = sessionPendingDeletion {
                Button("Kill Session", role: .destructive) {
                    deleteSession(session, killTmux: true)
                    sessionPendingDeletion = nil
                }
                Button("Detach Only") {
                    deleteSession(session, killTmux: false)
                    sessionPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    sessionPendingDeletion = nil
                }
            }
        } message: {
            Text("Kill the tmux session on the host, or just detach from it? Detaching keeps the session running so you can reattach later.")
        }
        .onChange(of: selectedSession) { _, _ in
            syncActiveRoomSelection()
        }
        .onChange(of: navigationPath) { oldPath, newPath in
            // After a pop, wait for the animation to finish before pushing the deep-link destination.
            if newPath.count < oldPath.count, foregroundNotifications.pendingDeepLinkRoomId != nil {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    consumePendingDeepLink()
                }
            }
            syncActiveRoomSelection()
        }
    }

    private var usesSplitView: Bool {
        horizontalSizeClass == .regular
    }

    @ViewBuilder
    private func sidebarContent() -> some View {
        sessionSectionedList()
            .navigationTitle("Sessions")
            .toolbar { toolbarContent }
    }

    private func handleTap(_ session: SavedSession) {
        if usesSplitView {
            selectedSession = session
        } else {
            navigationPath.append(session)
        }
    }

    private func deleteSession(_ session: SavedSession, killTmux: Bool) {
        GoVibeAnalytics.log("session_deleted", parameters: ["session_id": session.roomId, "kill_tmux": killTmux])
        userDeletingIds.insert(session.roomId)
        Task {
            await store.deleteSession(session, killTmux: killTmux)
            userDeletingIds.remove(session.roomId)
            if selectedSession == session { selectedSession = nil }
            navigationPath.removeAll { $0.roomId == session.roomId }
        }
    }

    private var activeRoomId: String? {
        if usesSplitView {
            selectedSession?.roomId
        } else {
            navigationPath.last?.roomId
        }
    }

    private func syncActiveRoomSelection() {
        foregroundNotifications.setActiveRoomId(activeRoomId)
    }

    private func consumePendingDeepLink() {
        guard let roomId = foregroundNotifications.pendingDeepLinkRoomId,
              let session = store.sessions.first(where: { $0.roomId == roomId }) else { return }
        foregroundNotifications.pendingDeepLinkRoomId = nil
        if usesSplitView {
            selectedSession = session
        } else {
            navigationPath = [session]
        }
    }

    // MARK: - Sectioned List

    @ViewBuilder
    private func sessionSectionedList() -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .padding()
                }

                ForEach(store.hosts) { host in
                    Section(header: iosSectionHeader(title: host.name)) {
                        let hostSessions = store.sessions(for: host.id)
                        if !hostSessions.isEmpty {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                                ForEach(hostSessions) { session in
                                    SessionCardItem(
                                        session: session,
                                        isSelected: session == selectedSession,
                                        onTap: { handleTap(session) },
                                        onDelete: { sessionPendingDeletion = session }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        } else {
                            Text("No active sessions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        }

                        Button {
                            createSessionForHost = host
                        } label: {
                            Label("New Terminal Session", systemImage: "plus")
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .clipShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("new_session_\(host.id)")
                    }
                }

                if store.hosts.isEmpty && !store.isLoading {
                    emptyStateView
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 40)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func iosSectionHeader(title: String) -> some View {
        HStack {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .textCase(nil)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sessionRowButton(_ session: SavedSession) -> some View {
        Button {
            handleTap(session)
        } label: {
            HStack {
                sessionRowLabel(session)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            session == selectedSession
            ? Color.accentColor.opacity(0.18)
            : Color.clear
        )
    }

    private let hostDownloadURL = URL(string: "https://govibe-783119.web.app")!

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Image("HostAppIcon", bundle: .main)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Image(systemName: "chevron.forward.2")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)

                Image(systemName: "macbook")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
            }

            Text("Download GoVibe Host on your macOS. After signing in to the same account, your host and sessions will appear here.")
                .font(.body)

            Spacer()

            VStack(spacing: 12) {
                Link(destination: hostDownloadURL) {
                    Label("Learn more", systemImage: "globe")
                        .font(.body.weight(.medium))
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)

                ShareLink(item: hostDownloadURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.body.weight(.medium))
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, 32)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                if authController.isAuthenticated {
                    Button(role: .destructive) {
                        authController.signOut()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            } label: {
                Image(systemName: "gear")
            }
            .accessibilityIdentifier("settings_button")
        }

        ToolbarItem(placement: .topBarTrailing) {
            if !store.hosts.isEmpty {
                Menu {
                    ForEach(store.hosts) { host in
                        Button {
                            createSessionForHost = host
                        } label: {
                            Label("New Session on \(host.name)", systemImage: "terminal")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(.tint)
                }
                .accessibilityIdentifier("add_session_button")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("refresh_session_button")
            }
        }
    }

    // MARK: - Row Label

    @ViewBuilder
    private func sessionRowLabel(_ session: SavedSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: session.kind?.iconName ?? "questionmark.circle")
                .foregroundStyle(session.kind == nil ? Color.secondary : Color.primary)
                .frame(width: 24)
            Text(session.sessionId)
                .font(.body)
        }
    }

    // MARK: - Snapshot helpers

    private func saveSnapshot(image: UIImage, date: Date, roomId: String) {
        let url = SessionStore.thumbnailURL(for: roomId)
        if let data = image.jpegData(compressionQuality: 0.7) {
            try? data.write(to: url)
        }
        store.update(roomId: roomId, lastActiveAt: date)
    }
}

// MARK: - Helpers

private struct SessionPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Select a Session",
            systemImage: "rectangle.split.2x1",
            description: Text("Choose a Mac session from the sidebar to get started.")
        )
        .accessibilityIdentifier("session_detail_placeholder")
    }
}

private struct SessionCardItem: View {
    let session: SavedSession
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onTap) {
            SessionCardView(session: session, thumbnail: thumbnail, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityIdentifier("session_card_\(session.roomId)")
        .task(id: session.lastActiveAt) {
            let url = SessionStore.thumbnailURL(for: session.roomId)
            thumbnail = UIImage(contentsOfFile: url.path)
        }
    }
}

private struct SessionCardView: View {
    let session: SavedSession
    let thumbnail: UIImage?
    let isSelected: Bool

    var body: some View {
        // Color.clear + aspectRatio(1, .fit) is the size anchor — the grid column width
        // determines width, aspectRatio makes height == width. Image is overlaid so it
        // never drives the card height, and top-aligned so the top of the screenshot shows.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .top) {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                } else {
                    Color(.systemGray5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            Image(systemName: session.kind?.iconName ?? "rectangle.on.rectangle")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipped()
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.sessionId)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let summary = session.lastConversationSummary {
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(2)
                    } else if let lastActiveAt = session.lastActiveAt {
                        Text(lastActiveAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                }
            }
    }

}

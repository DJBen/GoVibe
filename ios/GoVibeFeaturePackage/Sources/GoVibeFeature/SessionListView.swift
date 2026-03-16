import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SessionListView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var store = SessionStore()
    @State private var foregroundNotifications = ForegroundNotificationCoordinator.shared
    @State private var selectedSession: SavedSession?
    @State private var navigationPath: [SavedSession] = []
    @State private var showingAddHost = false
    @State private var createSessionForHost: HostInfo?

    var body: some View {
        Group {
            if usesSplitView {
                NavigationSplitView {
                    sidebarContent()
                } detail: {
                    if let selectedSession {
                        SessionDetailView(
                            roomId: selectedSession.roomId,
                            presentationMode: .regular,
                            onExit: { self.selectedSession = nil },
                            onKindDiscovered: { kind in store.update(roomId: selectedSession.roomId, kind: kind) },
                            onStatusChanged: { status in store.update(roomId: selectedSession.roomId, relayStatus: status) }
                        )
#if canImport(UIKit)
                        .withSnapshot { image, date in
                            saveSnapshot(image: image, date: date, roomId: selectedSession.roomId)
                        }
#endif
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
                                roomId: session.roomId,
                                presentationMode: .compact,
                                onKindDiscovered: { kind in store.update(roomId: session.roomId, kind: kind) },
                                onStatusChanged: { status in store.update(roomId: session.roomId, relayStatus: status) }
                            )
#if canImport(UIKit)
                            .withSnapshot { image, date in
                                saveSnapshot(image: image, date: date, roomId: session.roomId)
                            }
#endif
                        }
                }
            }
        }
        .sheet(isPresented: $showingAddHost) {
            AddHostView(store: store)
        }
        .sheet(item: $createSessionForHost) { host in
            SessionCreateView(host: host, store: store)
        }
        .overlay(alignment: .top) {
            if let banner = foregroundNotifications.banner {
                InAppNotificationBannerView(
                    banner: banner,
                    onTap: { openSession(for: banner) },
                    onDismiss: { foregroundNotifications.dismissBanner() }
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .accessibilityIdentifier("session_list_view")
        .task {
            await store.refresh()
            syncActiveRoomSelection()
        }
        .onChange(of: store.sessions) { _, sessions in
            if let selectedSession, !sessions.contains(selectedSession) {
                self.selectedSession = nil
            }
            syncActiveRoomSelection()
        }
        .onChange(of: selectedSession) { _, _ in
            syncActiveRoomSelection()
        }
        .onChange(of: navigationPath) { _, _ in
            syncActiveRoomSelection()
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: foregroundNotifications.banner)
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

    private func deleteSession(_ session: SavedSession) {
        store.delete(roomId: session.roomId)
        if selectedSession == session {
            selectedSession = nil
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

    private func openSession(for banner: InAppNotificationBanner) {
        foregroundNotifications.dismissBanner()
        guard let roomId = banner.roomId,
              let session = store.sessions.first(where: { $0.roomId == roomId }) else { return }

        if usesSplitView {
            selectedSession = session
        } else {
            navigationPath = [session]
        }
    }

    // MARK: - Sectioned List

    private func sessionSectionedList() -> some View {
        List {
            if let errorMessage = store.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            // One section per registered host
            ForEach(store.hosts) { host in
                Section {
                    let hostSessions = store.sessions(for: host.id)
#if canImport(UIKit)
                    if !hostSessions.isEmpty {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(hostSessions) { session in
                                SessionCardItem(
                                    session: session,
                                    isSelected: session == selectedSession,
                                    onTap: { handleTap(session) },
                                    onDelete: { deleteSession(session) }
                                )
                            }
                        }
                        .padding(.vertical, 8)
                        .listRowInsets(.init())
                        .listRowBackground(Color.clear)
                    }
#else
                    ForEach(hostSessions) { session in
                        sessionRowButton(session)
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteSession(session)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .accessibilityIdentifier("session_row_\(session.roomId)")
                    }
                    .onDelete { offsets in
                        let sessions = store.sessions(for: host.id)
                        for index in offsets {
                            deleteSession(sessions[index])
                        }
                    }
#endif

                    Button {
                        createSessionForHost = host
                    } label: {
                        Label("New Terminal Session", systemImage: "plus")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                    .accessibilityIdentifier("new_session_\(host.id)")
                } header: {
                    Text(host.name)
                        .textCase(nil)
                        .contextMenu {
                            Button(role: .destructive) {
                                store.removeHost(id: host.id)
                                if let selected = selectedSession, selected.hostId == host.id {
                                    selectedSession = nil
                                }
                            } label: {
                                Label("Remove Host", systemImage: "trash")
                            }
                        }
                }
            }

            // "Other" section for legacy sessions with no host
            let uncategorized = store.sessionsWithoutHost
            if !uncategorized.isEmpty {
                Section("Other") {
#if canImport(UIKit)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(uncategorized) { session in
                            SessionCardItem(
                                session: session,
                                isSelected: session == selectedSession,
                                onTap: { handleTap(session) },
                                onDelete: { deleteSession(session) }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                    .listRowInsets(.init())
                    .listRowBackground(Color.clear)
#else
                    ForEach(uncategorized) { session in
                        sessionRowButton(session)
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteSession(session)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { offsets in
                        let sessions = store.sessionsWithoutHost
                        for index in offsets {
                            deleteSession(sessions[index])
                        }
                    }
#endif
                }
            }

            // Empty state when no hosts configured
            if store.hosts.isEmpty && store.sessionsWithoutHost.isEmpty && !store.isLoading {
                emptyStateRow
            }
        }
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

    @ViewBuilder
    private var emptyStateRow: some View {
        Section {
            VStack(alignment: .center, spacing: 12) {
                Image(systemName: "desktopcomputer.and.arrow.down")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("No Hosts Added")
                    .font(.headline)
                Text("Tap + to add a Mac running GoVibe Host.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !store.hosts.isEmpty {
                    ForEach(store.hosts) { host in
                        Button {
                            createSessionForHost = host
                        } label: {
                            Label("New Session on \(host.name)", systemImage: "terminal")
                        }
                    }
                    Divider()
                }
                Button {
                    showingAddHost = true
                } label: {
                    Label("Add Mac Host", systemImage: "desktopcomputer.and.arrow.down")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityIdentifier("add_session_button")
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
            VStack(alignment: .leading, spacing: 2) {
                Text(session.roomId)
                    .font(.body)
                Text(session.lastRelayStatus ?? "Never connected")
                    .font(.caption)
                    .foregroundStyle(statusColor(session.lastRelayStatus))
            }
        }
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "Connected":                        return .green
        case "Connecting...", "Waiting for Mac": return .orange
        default:                                 return .secondary
        }
    }

    // MARK: - Snapshot helpers

#if canImport(UIKit)
    private func saveSnapshot(image: UIImage, date: Date, roomId: String) {
        if let data = image.jpegData(compressionQuality: 0.7) {
            try? data.write(to: SessionStore.thumbnailURL(for: roomId))
        }
        store.update(roomId: roomId, lastActiveAt: date)
    }
#endif
}

// MARK: - Helpers

private struct SessionPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Select a Session",
            systemImage: "rectangle.split.2x1",
            description: Text("Choose a session from the sidebar or add a new Mac host to get started.")
        )
        .accessibilityIdentifier("session_detail_placeholder")
    }
}

#if canImport(UIKit)
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
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusDotColor(session.lastRelayStatus))
                            .frame(width: 8, height: 8)
                        Text(session.roomId)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    if let lastActiveAt = session.lastActiveAt {
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

    private func statusDotColor(_ status: String?) -> Color {
        switch status {
        case "Connected":                        return .green
        case "Connecting...", "Waiting for Mac": return .orange
        default:                                 return .gray
        }
    }
}
#endif

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SessionListView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var store = SessionStore()
    @State private var newRoomId = ""
    @State private var showingAddAlert = false
    @State private var selectedSession: SavedSession?
    @State private var navigationPath: [SavedSession] = []

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
        .alert("New Session", isPresented: $showingAddAlert) {
            TextField("Room ID", text: $newRoomId)
                .autocorrectionDisabled()
                .modifier(NeverAutocapitalize())
            Button("Add") {
                store.add(roomId: newRoomId)
                newRoomId = ""
            }
            Button("Cancel", role: .cancel) {
                newRoomId = ""
            }
        }
        .accessibilityIdentifier("session_list_view")
        .task {
            await store.refresh()
        }
        .onChange(of: store.sessions) { _, sessions in
            if let selectedSession, !sessions.contains(selectedSession) {
                self.selectedSession = nil
            }
        }
    }

    private var usesSplitView: Bool {
        horizontalSizeClass == .regular
    }

    @ViewBuilder
    private func sidebarContent() -> some View {
#if canImport(UIKit)
        sessionGrid()
#else
        if usesSplitView {
            splitSessionList()
        } else {
            sessionList(selection: nil)
        }
#endif
    }

    private func handleTap(_ session: SavedSession) {
        if usesSplitView {
            selectedSession = session
        } else {
            navigationPath.append(session)
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        let removed = offsets.compactMap { index in
            store.sessions.indices.contains(index) ? store.sessions[index] : nil
        }
        store.delete(at: offsets)
        if let selectedSession, removed.contains(selectedSession) {
            self.selectedSession = nil
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingAddAlert = true
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

    // MARK: - Grid (UIKit)

#if canImport(UIKit)
    private func sessionGrid() -> some View {
        VStack(spacing: 0) {
            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(store.sessions) { session in
                        SessionCardView(
                            session: session,
                            thumbnail: loadThumbnail(for: session.roomId),
                            isSelected: session == selectedSession
                        )
                        .onTapGesture { handleTap(session) }
                        .contextMenu {
                            Button(role: .destructive) {
                                if let i = store.sessions.firstIndex(of: session) {
                                    deleteSessions(at: IndexSet([i]))
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityIdentifier("session_card_\(session.roomId)")
                    }
                }
                .padding(14)
            }
        }
        .navigationTitle("Sessions")
        .toolbar { toolbarContent }
    }

    private func loadThumbnail(for roomId: String) -> UIImage? {
        let url = SessionStore.thumbnailURL(for: roomId)
        return UIImage(contentsOfFile: url.path)
    }

    private func saveSnapshot(image: UIImage, date: Date, roomId: String) {
        if let data = image.jpegData(compressionQuality: 0.7) {
            try? data.write(to: SessionStore.thumbnailURL(for: roomId))
        }
        store.update(roomId: roomId, lastActiveAt: date)
    }
#endif

    // MARK: - Legacy list (non-UIKit fallback)

    private func splitSessionList() -> some View {
        List {
            if let errorMessage = store.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            ForEach(store.sessions) { session in
                Button {
                    selectedSession = session
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
                .accessibilityIdentifier("session_sidebar_row_\(session.roomId)")
            }
            .onDelete { offsets in
                deleteSessions(at: offsets)
            }
        }
        .navigationTitle("Sessions")
        .toolbar {
            toolbarContent
        }
    }

    private func sessionList(selection: Binding<SavedSession?>?) -> some View {
        List(selection: selection) {
            if let errorMessage = store.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            ForEach(store.sessions) { session in
                NavigationLink(value: session) {
                    sessionRowLabel(session)
                }
            }
            .onDelete { offsets in
                deleteSessions(at: offsets)
            }
        }
        .navigationTitle("Sessions")
        .toolbar {
            toolbarContent
        }
    }

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
}

// MARK: - SessionCardView

#if canImport(UIKit)
private struct SessionCardView: View {
    let session: SavedSession
    let thumbnail: UIImage?
    let isSelected: Bool

    private var isDisconnected: Bool {
        let s = session.lastRelayStatus
        return s == nil || s == "Disconnected" || s == "Peer disconnected"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background / thumbnail — Color.clear anchors the square layout;
            // the image sits in an overlay so it can't push the cell taller.
            if let thumbnail {
                Color.clear
                    .overlay(alignment: .top) {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                    }
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color(white: 0.12))
                    .overlay {
                        Image(systemName: session.kind?.iconName ?? "questionmark.circle")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                    }
            }

            // Bottom metadata strip with gradient that only covers the text area
            VStack(alignment: .leading, spacing: 3) {
                Text(session.roomId)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor(session.lastRelayStatus))
                        .frame(width: 6, height: 6)
                    Text(statusLabel(session.lastRelayStatus))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                    if let date = session.lastActiveAt {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 72)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "Connected":                        return .green
        case "Connecting...", "Waiting for Mac": return .orange
        default:                                 return Color(white: 0.5)
        }
    }

    private func statusLabel(_ status: String?) -> String {
        status ?? "Never connected"
    }
}
#endif

// MARK: - Helpers

private struct NeverAutocapitalize: ViewModifier {
    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content.textInputAutocapitalization(.never)
        #else
        content
        #endif
    }
}

private struct SessionPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Select a Session",
            systemImage: "rectangle.split.2x1",
            description: Text("Choose a session from the sidebar or add a new room to start a relay.")
        )
        .accessibilityIdentifier("session_detail_placeholder")
    }
}

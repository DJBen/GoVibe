import SwiftUI

struct SessionListView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var store = SessionStore()
    @State private var newRoomId = ""
    @State private var showingAddAlert = false
    @State private var selectedSession: SavedSession?

    var body: some View {
        Group {
            if usesSplitView {
                NavigationSplitView {
                    sidebarList(selection: $selectedSession)
                } detail: {
                    if let selectedSession {
                        SessionDetailView(
                            roomId: selectedSession.roomId,
                            presentationMode: .regular,
                            onExit: { self.selectedSession = nil }
                        )
                    } else {
                        SessionPlaceholderView()
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .accessibilityIdentifier("session_split_view")
            } else {
                NavigationStack {
                    sidebarList(selection: nil)
                        .navigationDestination(for: SavedSession.self) { session in
                            SessionDetailView(roomId: session.roomId, presentationMode: .compact)
                        }
                }
            }
        }
        .alert("New Session", isPresented: $showingAddAlert) {
            TextField("Room ID", text: $newRoomId)
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
    private func sidebarList(selection: Binding<SavedSession?>?) -> some View {
        if usesSplitView {
            splitSessionList()
#if canImport(UIKit)
                .listStyle(.sidebar)
#endif
        } else {
            sessionList(selection: selection)
        }
    }

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
                        Text(session.roomId)
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
                if usesSplitView {
                    Text(session.roomId)
                        .tag(Optional(session))
                } else {
                    NavigationLink(value: session) {
                        Text(session.roomId)
                    }
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

    private func deleteSessions(at offsets: IndexSet) {
        let removed = offsets.compactMap { index in
            store.sessions.indices.contains(index) ? store.sessions[index] : nil
        }
        store.delete(at: offsets)
        if let selectedSession, removed.contains(selectedSession) {
            self.selectedSession = nil
        }
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

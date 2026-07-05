import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebar()
        } content: {
            ChatView()
        } detail: {
            if state.selectedArtifactId != nil || !state.artifacts.isEmpty {
                ArtifactPanel()
            } else {
                Text("Select an artifact to view it here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: state.selectedArtifactId) { _, newValue in
            columnVisibility = newValue != nil ? .all : .doubleColumn
        }
        .navigationTitle("Cosmos")
        .tint(.cosmos)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.newSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New session (⌘N)")
            }
            ToolbarItem(placement: .principal) {
                HomeCodeSwitch()
                    .help("Switch between Home and Code")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.settings.appearance = Self.nextAppearance(after: state.settings.appearance)
                } label: {
                    Image(systemName: appearanceIcon)
                }
                .help("Appearance: \(state.settings.appearance) — click to cycle")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
        .sheet(isPresented: $state.showingSettings) {
            SettingsSheet()
        }
    }

    private var appearanceIcon: String {
        switch state.settings.appearance {
        case "light": return "sun.max.fill"
        case "dark": return "moon.fill"
        default: return "circle.lefthalf.filled"
        }
    }

    private static func nextAppearance(after current: String) -> String {
        switch current {
        case "system": return "light"
        case "light": return "dark"
        default: return "system"
        }
    }
}

/// Top-level nav: a compact "Home" / "Code" pill. Home always lands on the
/// most recently used chat/cowork submode — remembered in-memory only, so
/// each launch simply defaults to Chat the first time Home is reached from
/// Code.
struct HomeCodeSwitch: View {
    @EnvironmentObject var state: AppState
    @State private var lastHomeMode: AppMode = .chat

    var body: some View {
        HStack(spacing: 2) {
            homeButton
            codeButton
        }
        .padding(2)
        .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
        .onChange(of: state.settings.mode) { _, newValue in
            if newValue != .code { lastHomeMode = newValue }
        }
    }

    private var homeButton: some View {
        let isSelected = state.settings.mode != .code
        return Button {
            state.settings.mode = lastHomeMode
        } label: {
            Label("Home", systemImage: isSelected ? "house.fill" : "house")
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(isSelected ? Color(nsColor: .textBackgroundColor) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var codeButton: some View {
        let isSelected = state.settings.mode == .code
        return Button {
            state.settings.mode = .code
        } label: {
            Label(AppMode.code.label, systemImage: AppMode.code.icon)
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(isSelected ? Color(nsColor: .textBackgroundColor) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

struct SessionSidebar: View {
    @EnvironmentObject var state: AppState
    @State private var renamingSessionId: UUID?
    @State private var renameDraft = ""

    var body: some View {
        List {
            ForEach(state.sessions) { session in
                Button {
                    state.selectSession(session.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .lineLimit(1)
                            .fontWeight(session.id == state.currentSessionId ? .semibold : .regular)
                        Text(session.updatedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    session.id == state.currentSessionId
                        ? RoundedRectangle(cornerRadius: 6).fill(Color.cosmosSoft)
                        : nil
                )
                .contextMenu {
                    Button("Rename Session…") {
                        renameDraft = session.title
                        renamingSessionId = session.id
                    }
                    Button("Delete Session", role: .destructive) {
                        state.deleteSession(session.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        .alert("Rename Session", isPresented: Binding(
            get: { renamingSessionId != nil },
            set: { if !$0 { renamingSessionId = nil } }
        )) {
            TextField("Session name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingSessionId = nil }
            Button("Rename") {
                if let id = renamingSessionId {
                    state.renameSession(id, to: renameDraft)
                }
                renamingSessionId = nil
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button {
                    state.newSession()
                } label: {
                    Label("New Session", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    state.showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 18, height: 22)
                }
                .controlSize(.large)
                .help("Settings")
            }
            .padding(10)
        }
    }
}

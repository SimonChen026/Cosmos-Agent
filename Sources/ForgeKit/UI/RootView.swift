import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            SessionSidebar()
        } detail: {
            ChatView()
        }
        .navigationTitle("Cosmos")
    }
}

struct SessionSidebar: View {
    @EnvironmentObject var state: AppState

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
                        ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
                        : nil
                )
                .contextMenu {
                    Button("Delete Session", role: .destructive) {
                        state.deleteSession(session.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        .safeAreaInset(edge: .bottom) {
            Button {
                state.newSession()
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(10)
        }
    }
}

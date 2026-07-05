import SwiftUI

struct StatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            Button {
                WorkspacePicker.choose(state: state)
            } label: {
                Label(workspaceDisplay, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .buttonStyle(.plain)
            .help("Workspace — click to change")

            if state.activeProvider == nil {
                Divider().frame(height: 12)
                Button {
                    state.showingSettings = true
                } label: {
                    Label("No provider", systemImage: "cpu")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("No API key configured — click to open Settings")
            }

            Spacer()

            Text("in \(TokenFormat.compact(state.totalInputTokens)) · out \(TokenFormat.compact(state.totalOutputTokens)) · cache \(TokenFormat.compact(state.cacheReadTokens))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help("Token usage this app session (input · output · cache reads)")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .centeredContentColumn()
        .background(.bar)
    }

    private var workspaceDisplay: String {
        let path = state.workspaceURL.path
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }
}

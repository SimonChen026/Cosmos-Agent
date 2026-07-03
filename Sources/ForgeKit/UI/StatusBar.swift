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

            if state.settings.autoApprove {
                Label("Auto-approve", systemImage: "bolt.fill")
                    .foregroundStyle(.orange)
                    .help("All tool calls run without asking (Settings)")
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

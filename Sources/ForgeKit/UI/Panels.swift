import SwiftUI

// MARK: - Approval

struct ApprovalPanel: View {
    @EnvironmentObject var state: AppState
    let approval: AppState.PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: ToolPresentation.icon(for: approval.toolName))
                    .foregroundStyle(.orange)
                Text("Cosmos wants to run \(Text(ToolPresentation.displayName(approval.toolName)).bold())")
                Spacer()
            }
            Text(approval.summary)
                .font(.system(.callout,
                              design: approval.toolName == "bash" ? .monospaced : .default))
                .lineLimit(3)
                .textSelection(.enabled)
            if !inputPreview.isEmpty {
                Text(inputPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Deny", role: .destructive) {
                    approval.respond(.deny)
                }
                Button("Always Allow") {
                    approval.respond(.allowAlways)
                }
                .help("Auto-approve this tool (for bash: this command name) from now on")
                Button("Allow Once") {
                    approval.respond(.allowOnce)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.45))
        )
    }

    private var inputPreview: String {
        let pretty = approval.input.encodedString(pretty: true)
        guard pretty != "{}" else { return "" }
        let lines = pretty.components(separatedBy: "\n")
        if lines.count > 6 {
            return lines.prefix(6).joined(separator: "\n") + "\n…"
        }
        return pretty
    }
}

// MARK: - Todos

struct TodoPanel: View {
    let items: [TodoItem]
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            TodoChecklist(items: items)
                .padding(.top, 6)
        } label: {
            Label("Plan (\(completed)/\(items.count))", systemImage: "checklist")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    private var completed: Int {
        items.filter { $0.status == .completed }.count
    }
}

// MARK: - Errors

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.red.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.red.opacity(0.35))
        )
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.apiKeyPresent {
            ReadyEmptyState()
        } else {
            KeyOnboardingView()
        }
    }
}

/// First-run screen: the API key box plus optional endpoint/model fields.
/// Accepts many keys at once (one per line); each is auto-detected as
/// Anthropic or OpenAI-compatible.
struct KeyOnboardingView: View {
    @EnvironmentObject var state: AppState
    @State private var keyDraft = ""
    @State private var urlDraft = ""
    @State private var modelDraft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Cosmos")
                .font(.largeTitle.bold())
            Text("Paste your API keys to get started.")
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                TextField("sk-ant-…  /  sk-…   (one key per line)",
                          text: $keyDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(3...8)
                    .padding(10)
                    .frame(width: 440)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(nsColor: .separatorColor)))
                    .focused($focused)
                HStack(spacing: 8) {
                    TextField("Base URL — e.g. https://api.deepseek.com (optional)",
                              text: $urlDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    TextField("Model (optional)", text: $modelDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 150)
                }
                .frame(width: 440)
                Button("Save Keys") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Anthropic (sk-ant-…) and OpenAI-compatible keys are auto-detected;\nBase URL and model apply to OpenAI-format keys. Stored in the macOS Keychain — everything stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    private func save() {
        guard !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state.addKeys(keyDraft,
                      baseURL: urlDraft.trimmingCharacters(in: .whitespaces),
                      model: modelDraft.trimmingCharacters(in: .whitespaces))
        keyDraft = ""
        urlDraft = ""
        modelDraft = ""
    }
}

struct ReadyEmptyState: View {
    @EnvironmentObject var state: AppState

    private let examples = [
        "Summarize what this project does",
        "Find all TODO comments and fix the easiest one",
        "Write a README for this folder",
    ]

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Cosmos")
                .font(.largeTitle.bold())
            Text("Choose a workspace below, then ask for anything.")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button {
                        state.composerSeed = example
                    } label: {
                        Text(example)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                }
            }
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

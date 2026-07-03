import SwiftUI

struct ToolCallCard: View {
    @EnvironmentObject var state: AppState
    let toolUseId: String
    let name: String
    let input: JSONValue
    @State private var expanded = false

    private var result: (content: String, isError: Bool)? {
        for message in state.messages.reversed() {
            for block in message.blocks {
                if case .toolResult(let id, let content, let isError) = block, id == toolUseId {
                    return (content, isError)
                }
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            if expanded {
                detail
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: ToolPresentation.icon(for: name))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(ToolPresentation.displayName(name))
                .font(.caption.weight(.semibold))
            Text(ToolPresentation.summary(name: name, input: input, workspace: state.workspaceURL))
                .font(.system(.caption, design: name == "bash" ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            statusIcon
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIcon: some View {
        if let result {
            Image(systemName: result.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(result.isError ? .red : .green)
                .font(.caption)
        } else if state.isRunning {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if case .object(let object) = input, !object.isEmpty {
                Text(input.encodedString(pretty: true))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(12)
            }
            switch state.displayHints[toolUseId] {
            case .diff(let path, let old, let new):
                DiffView(path: path, old: old, new: new)
            case .todoList(let items):
                TodoChecklist(items: items)
            default:
                if let result {
                    resultBox(result.content, isError: result.isError)
                }
            }
            // Diffs/todos above replace the raw result body; still surface
            // errors so failures are never hidden.
            if let result, result.isError, state.displayHints[toolUseId] != nil {
                resultBox(result.content, isError: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func resultBox(_ content: String, isError: Bool) -> some View {
        ScrollView {
            Text(content.isEmpty ? "(no output)" : content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 300)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.18)))
    }
}

/// Simple removed-block / added-block rendering — no diff algorithm, the
/// tool already windows the content around the change.
struct DiffView: View {
    let path: String
    let old: String
    let new: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(path)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !old.isEmpty {
                        linesView(old, prefix: "-", tint: .red)
                    }
                    if !new.isEmpty {
                        linesView(new, prefix: "+", tint: .green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
        }
    }

    private func linesView(_ text: String, prefix: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.components(separatedBy: "\n").prefix(200).enumerated()),
                    id: \.offset) { _, line in
                Text("\(prefix) \(line)")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(tint.opacity(0.12))
            }
        }
    }
}

struct TodoChecklist: View {
    let items: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Image(systemName: icon(for: item.status))
                        .foregroundStyle(color(for: item.status))
                        .font(.caption)
                    Text(item.text)
                        .font(.caption)
                        .strikethrough(item.status == .completed)
                        .foregroundStyle(item.status == .completed
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
            }
        }
    }

    private func icon(for status: TodoStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "arrow.right.circle.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func color(for status: TodoStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        }
    }
}

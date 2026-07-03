import SwiftUI

struct MessageRow: View {
    @EnvironmentObject var state: AppState
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            if isToolResultCarrier {
                // Tool results render inside the matching ToolCallCard.
                EmptyView()
            } else {
                userBubble
            }
        } else {
            assistantBlocks
        }
    }

    private var isToolResultCarrier: Bool {
        !message.blocks.isEmpty && message.blocks.allSatisfy {
            if case .toolResult = $0 { return true } else { return false }
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            Text(message.plainText)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.22))
                )
        }
    }

    private var assistantBlocks: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    MarkdownText(text: text)
                case .thinking(let text, _):
                    ThinkingDisclosure(text: text)
                case .toolUse(let id, let name, let input):
                    ToolCallCard(toolUseId: id, name: name, input: input)
                case .toolResult:
                    EmptyView()   // never appears in assistant messages
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ThinkingDisclosure: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label("Thought for a moment", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .disclosureGroupStyle(.automatic)
    }
}

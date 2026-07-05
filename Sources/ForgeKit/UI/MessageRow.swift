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

    private var userImages: [(mediaType: String, base64: String)] {
        message.blocks.compactMap {
            if case .image(let mediaType, let base64) = $0 { return (mediaType, base64) } else { return nil }
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 6) {
                if !userImages.isEmpty {
                    ForEach(Array(userImages.enumerated()), id: \.offset) { _, image in
                        ImageBlockThumbnail(base64: image.base64)
                    }
                }
                if !message.plainText.isEmpty {
                    Text(message.plainText)
                        .font(.proseBody)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.cosmosSoft)
                        )
                }
            }
        }
    }

    /// True while this message is the one actively streaming: the run is
    /// still in flight and this is the newest message in the transcript.
    /// Used to gate the live shimmer so historical thinking blocks stay
    /// calm once a message has finished.
    private var isLiveMessage: Bool {
        state.isRunning && state.messages.last?.id == message.id
    }

    private var assistantBlocks: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .text(let text):
                    MarkdownText(text: text)
                case .thinking(let text, _):
                    ThinkingDisclosure(
                        text: text,
                        isLive: isLiveMessage && index == message.blocks.count - 1
                    )
                case .toolUse(let id, let name, let input):
                    ToolCallCard(toolUseId: id, name: name, input: input)
                case .toolResult:
                    EmptyView()   // never appears in assistant messages
                case .image:
                    EmptyView()   // vision models don't emit images; guards exhaustiveness
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ThinkingDisclosure: View {
    let text: String
    /// Whether this thinking block is the one currently being streamed —
    /// only then do we show the live shimmering "Thinking…" label.
    var isLive: Bool = false
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
            if isLive {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    ShimmerText("Thinking…")
                }
            } else {
                Label("Thought for a moment", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .disclosureGroupStyle(.automatic)
    }
}

/// A calm, repeating opacity pulse over secondary-colored text — the
/// Claude-Code-style "still thinking" indicator. Plays only while its
/// caller considers the underlying content live (see `isLive` above).
struct ShimmerText: View {
    let text: String
    @State private var pulsed = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .opacity(pulsed ? 0.85 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                    pulsed = true
                }
            }
    }
}

/// Bounded thumbnail for an `.image` content block, decoded from base64.
struct ImageBlockThumbnail: View {
    let base64: String

    var body: some View {
        if let data = Data(base64Encoded: base64), let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
        }
    }
}

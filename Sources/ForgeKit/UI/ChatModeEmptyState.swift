import SwiftUI

/// Greeting shown above the composer on the centered Home landing (both
/// Chat and Cowork submodes) — mirrors the reference design's big centered
/// "Hey there" with a colorful sparkle mark.
struct HomeGreeting: View {
    @EnvironmentObject var state: AppState
    @State private var greeting = Self.randomGreeting()

    private static let chatGreetings = [
        "Hey there",
        "Welcome back",
        "What are we making today?",
        "Good to see you",
        "Ready when you are",
        "What's on your mind?",
        "Let's get into it",
        "Where should we start?",
    ]

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 40))
                .foregroundStyle(
                    LinearGradient(colors: [.orange, .pink, .purple, Theme.accent],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text(state.settings.mode == .cowork ? "Cowork" : greeting)
                .font(.system(size: 28, weight: .semibold))
            if state.settings.mode == .cowork {
                Text("Generate a document, or ask for anything.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { greeting = Self.randomGreeting() }
    }

    private static func randomGreeting() -> String {
        chatGreetings.randomElement() ?? "Hey there"
    }
}

/// The row of quick-action content below the composer on the Home landing —
/// a light conversational chip row for Chat, or the three document cards
/// for Cowork.
struct HomeQuickActions: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.settings.mode == .cowork {
            CoworkDocCards()
        } else {
            ChatQuickChips()
        }
    }
}

private struct ChatQuickChips: View {
    @EnvironmentObject var state: AppState

    private let chips: [(label: String, icon: String, seed: String)] = [
        ("Write", "pencil.line", "Help me write "),
        ("Learn", "graduationcap", "Explain "),
        ("Code", "chevron.left.forwardslash.chevron.right", "Help me code "),
        ("Life stuff", "leaf", "Help me with "),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(chips, id: \.label) { chip in
                Button {
                    state.composerSeed = chip.seed
                } label: {
                    Label(chip.label, systemImage: chip.icon)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
            }
        }
    }
}

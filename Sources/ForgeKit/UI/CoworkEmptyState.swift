import SwiftUI

/// Cowork's quick-action row on the Home landing: three giant, unmissable
/// buttons for generating Office documents.
struct CoworkDocCards: View {
    var body: some View {
        HStack(spacing: 16) {
            CoworkDocCard(
                icon: "doc.richtext.fill",
                title: "Word Document",
                subtitle: "Reports, letters, memos",
                seed: "Create a Word document about "
            )
            CoworkDocCard(
                icon: "rectangle.on.rectangle.fill",
                title: "Slides",
                subtitle: "A polished slide deck",
                seed: "Create a slide deck about "
            )
            CoworkDocCard(
                icon: "tablecells.fill",
                title: "Spreadsheet",
                subtitle: "Tables, data, calculations",
                seed: "Create a spreadsheet with "
            )
        }
    }
}

private struct CoworkDocCard: View {
    @EnvironmentObject var state: AppState
    let icon: String
    let title: String
    let subtitle: String
    let seed: String

    @State private var pressed = false

    var body: some View {
        Button {
            state.composerSeed = seed
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 42))
                    .foregroundStyle(Color.cosmos)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 210, height: 150)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .cosmosCard(cornerRadius: 16, padding: 0)
        .scaleEffect(pressed ? 0.97 : 1.0)
        .opacity(pressed ? 0.85 : 1.0)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}

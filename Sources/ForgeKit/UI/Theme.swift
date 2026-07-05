import SwiftUI

/// Shared visual language. One cosmic-indigo accent, a few tuned neutrals,
/// and small helpers so the whole app reads consistently (Claude-Code-style
/// calm surfaces and generous whitespace).
enum Theme {
    static let accent = Color(red: 0.42, green: 0.40, blue: 0.92)   // cosmic indigo
    static let accentSoft = Color(red: 0.42, green: 0.40, blue: 0.92).opacity(0.14)

    /// Panel/card surface that sits a step above the window background.
    static var surface: Color { Color(nsColor: .controlBackgroundColor) }
    static var hairline: Color { Color(nsColor: .separatorColor) }

    /// Width of the centered reading column shared by the transcript,
    /// composer, and status row (Claude-Code-style centered layout).
    static let contentMaxWidth: CGFloat = 760
}

extension Color {
    static let cosmos = Theme.accent
    static let cosmosSoft = Theme.accentSoft
}

extension Font {
    /// Slightly larger-than-default body size for the primary reading
    /// surfaces (assistant prose, user bubbles, composer) — closer to
    /// Claude Code's terminal sizing, without touching dense/caption UI.
    static let proseBody = Font.system(size: 15)
}

extension View {
    /// A rounded card with a hairline border — the app's standard container.
    func cosmosCard(cornerRadius: CGFloat = 12, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }

    /// Centers content in a max-width reading column while staying fluid
    /// (and full-width) below that width — the shared layout for the
    /// transcript, composer, and status row.
    func centeredContentColumn(maxWidth: CGFloat = Theme.contentMaxWidth) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

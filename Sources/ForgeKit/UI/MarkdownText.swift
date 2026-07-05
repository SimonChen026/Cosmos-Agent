import SwiftUI
import AppKit

/// Lightweight markdown rendering: fenced code blocks get monospaced boxes
/// with a copy button; other text renders line-wise with heading/bullet
/// styling and inline markdown via AttributedString. Falls back to plain
/// text on parse failure.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                case .prose(let prose):
                    ProseView(text: prose)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Segment {
        case prose(String)
        case code(String, language: String)
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var prose: [String] = []
        var code: [String] = []
        var language = ""
        var inFence = false

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    result.append(.code(code.joined(separator: "\n"), language: language))
                    code = []
                    inFence = false
                } else {
                    if !prose.isEmpty {
                        result.append(.prose(prose.joined(separator: "\n")))
                        prose = []
                    }
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inFence = true
                }
                continue
            }
            if inFence { code.append(line) } else { prose.append(line) }
        }
        if inFence, !code.isEmpty {
            result.append(.code(code.joined(separator: "\n"), language: language))
        } else if !prose.isEmpty {
            result.append(.prose(prose.joined(separator: "\n")))
        }
        return result
    }
}

private struct ProseView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()),
                    id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if trimmed.hasPrefix("### ") {
            inline(String(trimmed.dropFirst(4))).font(.headline)
        } else if trimmed.hasPrefix("## ") {
            inline(String(trimmed.dropFirst(3))).font(.title3.bold())
        } else if trimmed.hasPrefix("# ") {
            inline(String(trimmed.dropFirst(2))).font(.title2.bold())
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").font(.proseBody)
                inline(String(trimmed.dropFirst(2))).font(.proseBody)
            }
            .padding(.leading, 8)
        } else if trimmed.hasPrefix("> ") {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                inline(String(trimmed.dropFirst(2))).font(.proseBody).foregroundStyle(.secondary)
            }
        } else {
            inline(line).font(.proseBody)
        }
    }

    private func inline(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }
}

struct CodeBlockView: View {
    let code: String
    let language: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.22)))
            HStack(spacing: 6) {
                if !language.isEmpty {
                    Text(language)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .opacity(hovering || copied ? 1 : 0.35)
            }
            .padding(6)
        }
        .onHover { hovering = $0 }
    }
}

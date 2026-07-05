import SwiftUI
import AppKit
import WebKit

struct ArtifactPanel: View {
    @EnvironmentObject var state: AppState
    @State private var showingSource = false
    @State private var copied = false

    private var artifact: Artifact? {
        if let id = state.selectedArtifactId, let match = state.artifacts.first(where: { $0.id == id }) {
            return match
        }
        return state.artifacts.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let artifact {
                header(for: artifact)
                Divider()
                body(for: artifact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No artifact yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func header(for artifact: Artifact) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if state.artifacts.count > 1 {
                    Menu {
                        ForEach(state.artifacts) { item in
                            Button {
                                state.selectedArtifactId = item.id
                            } label: {
                                Label(item.title, systemImage: item.id == artifact.id ? "checkmark" : "")
                            }
                        }
                    } label: {
                        Text(artifact.title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                } else {
                    Text(artifact.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                kindBadge(artifact.kind)
                Spacer()
                if artifact.kind == "html" || artifact.kind == "svg" {
                    Button {
                        showingSource.toggle()
                    } label: {
                        Image(systemName: showingSource ? "eye" : "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .help(showingSource ? "Show preview" : "Show source")
                }
                Button {
                    copyToPasteboard(artifact.content)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy to clipboard")
                Button {
                    saveToFile(artifact)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Save to file…")
                Button {
                    state.selectedArtifactId = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func kindBadge(_ kind: String) -> some View {
        Text(kind.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
    }

    @ViewBuilder
    private func body(for artifact: Artifact) -> some View {
        switch artifact.kind {
        case "code":
            ScrollView {
                CodeBlockView(code: artifact.content, language: artifact.language ?? "")
                    .padding(12)
            }
        case "markdown":
            ScrollView {
                MarkdownText(text: artifact.content)
                    .padding(12)
            }
        case "html":
            if showingSource {
                sourceBox(artifact.content)
            } else {
                HTMLPreview(html: artifact.content)
            }
        case "svg":
            if showingSource {
                sourceBox(artifact.content)
            } else {
                HTMLPreview(html: "<html><body style=\"margin:0\">\(artifact.content)</body></html>")
            }
        case "mermaid":
            VStack(alignment: .leading, spacing: 6) {
                Text("Mermaid syntax (no renderer available offline)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                sourceBox(artifact.content)
            }
        default:
            sourceBox(artifact.content)
        }
    }

    private func sourceBox(_ content: String) -> some View {
        ScrollView {
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyToPasteboard(_ content: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private func saveToFile(_ artifact: Artifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFilename(for: artifact)
        if panel.runModal() == .OK, let url = panel.url {
            try? artifact.content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func defaultFilename(for artifact: Artifact) -> String {
        let base = artifact.title.isEmpty ? "artifact" : artifact.title
        let ext: String
        switch artifact.kind {
        case "markdown": ext = "md"
        case "html": ext = "html"
        case "svg": ext = "svg"
        case "mermaid": ext = "mmd"
        case "code": ext = fileExtension(forLanguage: artifact.language)
        default: ext = "txt"
        }
        return "\(base).\(ext)"
    }

    private func fileExtension(forLanguage language: String?) -> String {
        switch (language ?? "").lowercased() {
        case "swift": return "swift"
        case "python", "py": return "py"
        case "javascript", "js": return "js"
        case "typescript", "ts": return "ts"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "shell", "bash", "sh": return "sh"
        case "go": return "go"
        case "rust", "rs": return "rs"
        case "c": return "c"
        case "cpp", "c++": return "cpp"
        case "java": return "java"
        case "html": return "html"
        case "css": return "css"
        default: return "txt"
        }
    }
}

/// Minimal live preview for HTML/SVG artifacts, with source display handled
/// by the caller toggling this view out.
private struct HTMLPreview: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

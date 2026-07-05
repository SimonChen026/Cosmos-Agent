import SwiftUI
import AppKit

// =====================================================================
// Small UI-layer helpers shared across views. The UI never talks to the
// engine or tools directly — everything here derives presentation from
// recorded state (tool inputs, settings, token counts).
// =====================================================================

// MARK: - Model choices

/// `ModelCatalog.models` is a tuple array; ForEach cannot key-path into
/// tuples, so wrap entries in an Identifiable struct.
struct ModelChoice: Identifiable {
    let id: String
    let label: String
    let vision: Bool

    static let all: [ModelChoice] = ModelCatalog.models.map {
        ModelChoice(id: $0.id, label: $0.label, vision: $0.vision)
    }

    static func label(for id: String) -> String {
        all.first(where: { $0.id == id })?.label ?? id
    }
}

// MARK: - Tool presentation

/// Maps tool names to SF Symbols, display names and one-line summaries.
/// Summaries are derived from the recorded `toolUse` input because the UI
/// must not call tool implementations.
enum ToolPresentation {
    static func icon(for name: String) -> String {
        switch name {
        case "read_file": return "doc.text"
        case "write_file": return "square.and.pencil"
        case "edit_file": return "pencil.line"
        case "list_dir": return "folder"
        case "glob": return "doc.text.magnifyingglass"
        case "grep": return "magnifyingglass"
        case "bash": return "terminal"
        case "todo_write": return "checklist"
        case "create_artifact": return "puzzlepiece.extension"
        case "agent": return "person.2.fill"
        case "create_docx": return "doc.richtext"
        case "create_pptx": return "rectangle.on.rectangle"
        case "create_xlsx": return "tablecells"
        case "web_search": return "magnifyingglass.circle"
        default: return "wrench.and.screwdriver"
        }
    }

    static func displayName(_ name: String) -> String {
        switch name {
        case "read_file": return "Read"
        case "write_file": return "Write"
        case "edit_file": return "Edit"
        case "list_dir": return "List"
        case "glob": return "Glob"
        case "grep": return "Grep"
        case "bash": return "Shell"
        case "todo_write": return "Todos"
        case "create_artifact": return "Artifact"
        case "agent": return "Agent"
        case "create_docx": return "Word Doc"
        case "create_pptx": return "Slides"
        case "create_xlsx": return "Spreadsheet"
        case "web_search": return "Web Search"
        default: return name
        }
    }

    static func summary(name: String, input: JSONValue, workspace: URL) -> String {
        func displayPath(_ key: String) -> String? {
            guard let raw = input[key]?.stringValue, !raw.isEmpty else { return nil }
            return Util.displayPath(Util.resolvePath(raw, workspace: workspace), workspace: workspace)
        }
        switch name {
        case "read_file", "write_file", "edit_file":
            return displayPath("path") ?? "…"
        case "list_dir":
            return displayPath("path") ?? "."
        case "glob":
            return input["pattern"]?.stringValue ?? "…"
        case "grep":
            var s = input["pattern"]?.stringValue ?? "…"
            if let g = input["glob"]?.stringValue, !g.isEmpty { s += "  in \(g)" }
            return s
        case "bash":
            let firstLine = (input["command"]?.stringValue ?? "…")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first.map(String.init) ?? "…"
            return "$ " + String(firstLine.prefix(80))
        case "todo_write":
            let n = input["items"]?.arrayValue?.count ?? 0
            return "\(n) item\(n == 1 ? "" : "s")"
        case "create_artifact":
            return input["title"]?.stringValue ?? "untitled artifact"
        case "agent":
            return String((input["task"]?.stringValue ?? "…").prefix(70))
        case "create_docx":
            let n = input["paragraphs"]?.arrayValue?.count ?? 0
            return (displayPath("path") ?? "…") + "  (\(n) paragraph\(n == 1 ? "" : "s"))"
        case "create_pptx":
            let n = input["slides"]?.arrayValue?.count ?? 0
            return (displayPath("path") ?? "…") + "  (\(n) slide\(n == 1 ? "" : "s"))"
        case "create_xlsx":
            let n = input["rows"]?.arrayValue?.count ?? 0
            return (displayPath("path") ?? "…") + "  (\(n) row\(n == 1 ? "" : "s"))"
        case "web_search":
            return input["query"]?.stringValue ?? "…"
        default:
            return String(input.encodedString().prefix(80))
        }
    }

    /// Todo items encoded in a `todo_write` input, if parseable.
    static func todoItems(in input: JSONValue) -> [TodoItem]? {
        guard let array = input["items"]?.arrayValue, !array.isEmpty else { return nil }
        let items = array.compactMap { value -> TodoItem? in
            guard let text = value["text"]?.stringValue else { return nil }
            let id = value["id"]?.stringValue
                ?? value["id"]?.intValue.map { String($0) }
                ?? UUID().uuidString
            let status = value["status"]?.stringValue.flatMap(TodoStatus.init(rawValue:)) ?? .pending
            return TodoItem(id: id, text: text, status: status)
        }
        return items.isEmpty ? nil : items
    }
}

// MARK: - Token formatting

enum TokenFormat {
    /// "12.3k" / "1.2M" style compact counts for the status bar.
    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
}

// MARK: - Workspace picking

@MainActor
enum WorkspacePicker {
    /// Folder-only NSOpenPanel feeding `state.setWorkspace`.
    static func choose(state: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = state.workspaceURL
        panel.message = "Choose the folder Forge may read and edit."
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            state.setWorkspace(url)
        }
    }
}

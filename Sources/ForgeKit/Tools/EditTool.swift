import Foundation

struct EditTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "edit_file",
            description: "Replace an exact string in a file. `old_string` must match the file exactly (including whitespace) and be unique unless `replace_all` is true. You must read_file the file first.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute, ~/ or workspace-relative path."],
                    "old_string": ["type": "string", "description": "Exact text to replace."],
                    "new_string": ["type": "string", "description": "Replacement text."],
                    "replace_all": ["type": "boolean", "description": "Replace every occurrence (default false)."],
                ],
                "required": ["path", "old_string", "new_string"],
            ]
        )
    }

    var permissionClass: PermissionClass { .write }

    func summarize(input: JSONValue) -> String {
        "edit \(input["path"]?.stringValue ?? "?")"
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let path = input["path"]?.stringValue, !path.isEmpty else {
            return .error("edit_file: missing required parameter `path`.")
        }
        guard let oldString = input["old_string"]?.stringValue, !oldString.isEmpty else {
            return .error("edit_file: `old_string` must be a non-empty string.")
        }
        guard let newString = input["new_string"]?.stringValue else {
            return .error("edit_file: missing required parameter `new_string`.")
        }
        if oldString == newString {
            return .error("edit_file: old_string and new_string are identical.")
        }
        let replaceAll = input["replace_all"]?.boolValue ?? false

        let url = Util.resolvePath(path, workspace: context.workspaceRoot)
        let canonical = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .error("File not found: \(url.path)")
        }
        guard context.session.wasRead(canonical) else {
            return .error("You must read_file \(url.path) before editing it.")
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .error("Could not read \(url.path).")
        }

        let count = occurrences(of: oldString, in: content)
        if count == 0 {
            return .error("old_string not found in \(url.path) — re-read the file; it may have changed.")
        }
        if count > 1 && !replaceAll {
            return .error("old_string matches \(count) times in \(url.path). Provide more surrounding context to make it unique, or set replace_all=true.")
        }

        let updated: String
        if replaceAll {
            updated = content.replacingOccurrences(of: oldString, with: newString)
        } else if let range = content.range(of: oldString) {
            updated = content.replacingCharacters(in: range, with: newString)
        } else {
            return .error("old_string not found in \(url.path).")
        }

        do {
            try Data(updated.utf8).write(to: url, options: .atomic)
        } catch {
            return .error("Could not write \(url.path): \(error.localizedDescription)")
        }

        let display = Util.displayPath(url, workspace: context.workspaceRoot)
        let (oldWindow, newWindow) = diffWindows(
            old: content, new: updated, oldString: oldString, newLength: newString.count
        )
        return ToolOutput(
            content: "Edited \(display): replaced \(count) occurrence\(count == 1 ? "" : "s").",
            displayHint: .diff(path: display, old: oldWindow, new: newWindow)
        )
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: search) {
            count += 1
            search = found.upperBound..<haystack.endIndex
        }
        return count
    }

    /// ±20 lines of context around the first change, for the diff card.
    private func diffWindows(old: String, new: String, oldString: String,
                             newLength: Int) -> (String, String) {
        guard let range = old.range(of: oldString) else { return (old, new) }
        let context = 20
        let startLine = old[old.startIndex..<range.lowerBound]
            .components(separatedBy: "\n").count - 1
        let oldSpan = oldString.components(separatedBy: "\n").count

        func window(_ text: String, span: Int) -> String {
            let lines = text.components(separatedBy: "\n")
            let lo = max(0, startLine - context)
            let hi = min(lines.count, startLine + span + context)
            guard lo < hi else { return text }
            return lines[lo..<hi].joined(separator: "\n")
        }
        let newSpan = max(1, oldSpan)   // approximation is fine for a hint
        return (window(old, span: oldSpan), window(new, span: newSpan))
    }
}

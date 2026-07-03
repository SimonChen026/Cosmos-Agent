import Foundation

struct WriteTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "write_file",
            description: "Create or overwrite a file with the given content. Creates parent directories. To overwrite an existing file you must read_file it first. For partial changes prefer edit_file.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute, ~/ or workspace-relative path."],
                    "content": ["type": "string", "description": "Full new file content."],
                ],
                "required": ["path", "content"],
            ]
        )
    }

    var permissionClass: PermissionClass { .write }

    func summarize(input: JSONValue) -> String {
        "write \(input["path"]?.stringValue ?? "?")"
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let path = input["path"]?.stringValue, !path.isEmpty else {
            return .error("write_file: missing required parameter `path`.")
        }
        guard let content = input["content"]?.stringValue else {
            return .error("write_file: missing required parameter `content`.")
        }
        let url = Util.resolvePath(path, workspace: context.workspaceRoot)
        let canonical = url.standardizedFileURL.path
        let fm = FileManager.default

        var old = ""
        if fm.fileExists(atPath: url.path) {
            guard context.session.wasRead(canonical) else {
                return .error("\(url.path) already exists. read_file it first, then overwrite or edit_file it.")
            }
            old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            return .error("Could not write \(url.path): \(error.localizedDescription)")
        }
        context.session.markRead(canonical)

        let display = Util.displayPath(url, workspace: context.workspaceRoot)
        return ToolOutput(
            content: "Wrote \(content.utf8.count) bytes to \(display)",
            displayHint: .diff(path: display, old: capForHint(old), new: capForHint(content))
        )
    }

    private func capForHint(_ text: String, maxLines: Int = 400) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > maxLines else { return text }
        return lines.prefix(maxLines).joined(separator: "\n") + "\n…(truncated)"
    }
}

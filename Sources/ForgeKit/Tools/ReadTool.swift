import Foundation

struct ReadTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "read_file",
            description: "Read a text file, returning numbered lines. Reads up to `limit` lines (default 2000) starting at 1-based `offset`. Always read a file before editing it. Use glob to find files by name and grep to search contents.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute, ~/ or workspace-relative path."],
                    "offset": ["type": "integer", "description": "1-based line to start from (default 1)."],
                    "limit": ["type": "integer", "description": "Maximum lines to return (default 2000)."],
                ],
                "required": ["path"],
            ]
        )
    }

    var permissionClass: PermissionClass { .read }

    func summarize(input: JSONValue) -> String {
        "read \(input["path"]?.stringValue ?? "?")"
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let path = input["path"]?.stringValue, !path.isEmpty else {
            return .error("read_file: missing required parameter `path`.")
        }
        let url = Util.resolvePath(path, workspace: context.workspaceRoot)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return .error("File not found: \(url.path)")
        }
        if isDir.boolValue {
            return .error("\(url.path) is a directory — use list_dir instead.")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 10_000_000 {
            return .error("File is \(size / 1_000_000)MB — too large to read whole. Use bash (head/tail/sed) to sample it.")
        }
        if FileWalk.isBinary(url) {
            return .error("\(url.path) looks like a binary file and cannot be read as text.")
        }
        guard let data = try? Data(contentsOf: url) else {
            return .error("Could not read \(url.path).")
        }
        context.session.markRead(url.standardizedFileURL.path)

        let content = String(decoding: data, as: UTF8.self)
        if content.isEmpty {
            return ToolOutput(content: "(empty file)", displayHint: .fileContent(path: url.path))
        }

        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // trailing newline
        let total = lines.count

        let offset = max(1, input["offset"]?.intValue ?? 1)
        let limit = min(max(1, input["limit"]?.intValue ?? 2000), 20_000)
        guard offset <= total else {
            return .error("offset \(offset) is beyond the end of the file (\(total) lines).")
        }
        let end = min(total, offset + limit - 1)

        var out: [String] = []
        out.reserveCapacity(end - offset + 1)
        for n in offset...end {
            var line = lines[n - 1]
            if line.count > 2000 { line = String(line.prefix(2000)) + "…" }
            out.append(String(format: "%6d\t%@", n, line))
        }
        var text = out.joined(separator: "\n")
        if end < total {
            text += "\n…[lines \(offset)–\(end) of \(total); continue with offset=\(end + 1)]"
        }
        return ToolOutput(
            content: Util.truncateForModel(text, maxChars: 50_000),
            displayHint: .fileContent(path: url.path)
        )
    }
}

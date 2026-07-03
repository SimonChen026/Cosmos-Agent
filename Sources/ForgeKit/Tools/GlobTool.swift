import Foundation

struct GlobTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "glob",
            description: "Find files by name pattern (supports *, ?, ** — e.g. \"**/*.swift\"). Returns workspace-relative paths, newest first. Use grep to search file contents instead.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "pattern": ["type": "string", "description": "Glob pattern matched against the path relative to `path`."],
                    "path": ["type": "string", "description": "Directory to search (default: workspace root)."],
                ],
                "required": ["pattern"],
            ]
        )
    }

    var permissionClass: PermissionClass { .read }

    func summarize(input: JSONValue) -> String {
        "glob \(input["pattern"]?.stringValue ?? "?")"
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let pattern = input["pattern"]?.stringValue, !pattern.isEmpty else {
            return .error("glob: missing required parameter `pattern`.")
        }
        let base = Util.resolvePath(input["path"]?.stringValue ?? ".", workspace: context.workspaceRoot)
        guard FileManager.default.fileExists(atPath: base.path) else {
            return .error("Directory not found: \(base.path)")
        }
        guard let regex = try? NSRegularExpression(pattern: FileWalk.regexPattern(fromGlob: pattern)) else {
            return .error("glob: could not compile pattern \(pattern).")
        }

        let (files, truncatedWalk) = FileWalk.files(under: base)
        var matched: [(rel: String, mtime: Date)] = []
        for url in files {
            let rel = FileWalk.relativePath(of: url, under: base)
            let range = NSRange(rel.startIndex..., in: rel)
            guard regex.firstMatch(in: rel, range: range) != nil else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            matched.append((rel, mtime))
        }
        matched.sort { $0.mtime > $1.mtime }

        if matched.isEmpty {
            var msg = "No files match \(pattern)"
            if truncatedWalk { msg += " (search stopped early — directory tree is very large; narrow `path`)" }
            return ToolOutput(content: msg)
        }
        var note = ""
        if matched.count > 100 {
            note = "\n…[showing first 100 of \(matched.count) matches]"
            matched = Array(matched.prefix(100))
        }
        if truncatedWalk { note += "\n[directory tree very large — walk capped; narrow `path` for exhaustive results]" }
        return ToolOutput(content: matched.map(\.rel).joined(separator: "\n") + note)
    }
}

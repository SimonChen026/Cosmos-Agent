import Foundation

struct ListDirTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "list_dir",
            description: "List the entries of a directory (directories get a trailing /). Defaults to the workspace root. Use glob for recursive filename searches.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Directory to list (default: workspace root)."],
                ],
                "required": [],
            ]
        )
    }

    var permissionClass: PermissionClass { .read }

    func summarize(input: JSONValue) -> String {
        "list \(input["path"]?.stringValue ?? ".")"
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        let path = input["path"]?.stringValue ?? "."
        let url = Util.resolvePath(path, workspace: context.workspaceRoot)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return .error("Directory not found: \(url.path)")
        }
        guard isDir.boolValue else {
            return .error("\(url.path) is a file — use read_file instead.")
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return .error("Could not list \(url.path).")
        }

        var dirs: [String] = []
        var files: [String] = []
        for name in names where name != ".git" {
            var entryIsDir: ObjCBool = false
            let full = url.appendingPathComponent(name).path
            FileManager.default.fileExists(atPath: full, isDirectory: &entryIsDir)
            if entryIsDir.boolValue { dirs.append(name + "/") } else { files.append(name) }
        }
        dirs.sort()
        files.sort()

        var entries = dirs + files
        if entries.isEmpty { return ToolOutput(content: "(empty directory)") }
        var note = ""
        if entries.count > 500 {
            note = "\n…[\(entries.count - 500) more entries not shown]"
            entries = Array(entries.prefix(500))
        }
        return ToolOutput(content: entries.joined(separator: "\n") + note)
    }
}

import Foundation

struct GrepTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "grep",
            description: "Search file contents with a regular expression. Use glob to find files by name instead. output_mode \"files_with_matches\" (default) lists matching files; \"content\" shows matching lines as path:line: text.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "pattern": ["type": "string", "description": "Regular expression to search for."],
                    "path": ["type": "string", "description": "Directory or file to search (default: workspace root)."],
                    "glob": ["type": "string", "description": "Filter files by glob, e.g. \"*.swift\" (matches filename) or \"src/**/*.ts\" (matches relative path)."],
                    "output_mode": ["type": "string", "enum": ["files_with_matches", "content"]],
                ],
                "required": ["pattern"],
            ]
        )
    }

    var permissionClass: PermissionClass { .read }

    func summarize(input: JSONValue) -> String {
        var s = "grep \(input["pattern"]?.stringValue ?? "?")"
        if let g = input["glob"]?.stringValue { s += " in \(g)" }
        return s
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let pattern = input["pattern"]?.stringValue, !pattern.isEmpty else {
            return .error("grep: missing required parameter `pattern`.")
        }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            return .error("grep: invalid regex — \(error.localizedDescription)")
        }

        let base = Util.resolvePath(input["path"]?.stringValue ?? ".", workspace: context.workspaceRoot)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir) else {
            return .error("Path not found: \(base.path)")
        }

        var globRegex: NSRegularExpression?
        var globMatchesFilename = false
        if let glob = input["glob"]?.stringValue, !glob.isEmpty {
            globMatchesFilename = !glob.contains("/")
            globRegex = try? NSRegularExpression(pattern: FileWalk.regexPattern(fromGlob: glob))
            if globRegex == nil { return .error("grep: could not compile glob \(glob).") }
        }

        let contentMode = input["output_mode"]?.stringValue == "content"
        let candidates: [URL]
        var truncatedWalk = false
        if isDir.boolValue {
            let walk = FileWalk.files(under: base)
            candidates = walk.files
            truncatedWalk = walk.truncated
        } else {
            candidates = [base]
        }

        var matchingFiles: [String] = []
        var contentLines: [String] = []
        let fileCap = 50, lineCap = 200

        for url in candidates {
            let rel = FileWalk.relativePath(of: url, under: isDir.boolValue ? base : context.workspaceRoot)
            if let g = globRegex {
                let target = globMatchesFilename ? url.lastPathComponent : rel
                let r = NSRange(target.startIndex..., in: target)
                guard g.firstMatch(in: target, range: r) != nil else { continue }
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 2_000_000 || FileWalk.isBinary(url) { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            var fileMatched = false
            var lineNo = 0
            for line in text.components(separatedBy: "\n") {
                lineNo += 1
                let range = NSRange(line.startIndex..., in: line)
                guard regex.firstMatch(in: line, range: range) != nil else { continue }
                fileMatched = true
                if contentMode {
                    let shown = line.count > 400 ? String(line.prefix(400)) + "…" : line
                    contentLines.append("\(rel):\(lineNo): \(shown)")
                    if contentLines.count >= lineCap { break }
                } else {
                    break
                }
            }
            if fileMatched { matchingFiles.append(rel) }
            if contentMode && contentLines.count >= lineCap { break }
            if !contentMode && matchingFiles.count >= fileCap { break }
        }

        var note = truncatedWalk ? "\n[directory tree very large — walk capped; narrow `path`]" : ""
        if contentMode {
            if contentLines.isEmpty { return ToolOutput(content: "No matches." + note) }
            if contentLines.count >= lineCap { note = "\n…[output capped at \(lineCap) lines]" + note }
            return ToolOutput(content: Util.truncateForModel(
                contentLines.joined(separator: "\n") + note, maxChars: 50_000))
        }
        if matchingFiles.isEmpty { return ToolOutput(content: "No matches." + note) }
        if matchingFiles.count >= fileCap { note = "\n…[capped at \(fileCap) files]" + note }
        return ToolOutput(content: matchingFiles.joined(separator: "\n") + note)
    }
}

import Foundation

/// Recursive file enumeration shared by glob and grep. Skips VCS/build
/// directories and descends into no hidden directories; caps the walk so a
/// home-directory workspace cannot stall a tool call.
enum FileWalk {
    static let skipDirs: Set<String> = [
        ".git", "node_modules", ".build", "dist", ".swiftpm",
        ".venv", "__pycache__", "DerivedData",
    ]

    static func files(under base: URL, maxVisited: Int = 20_000) -> (files: [URL], truncated: Bool) {
        var out: [URL] = []
        var visited = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: keys, options: []
        ) else { return ([], false) }

        while let item = enumerator.nextObject() as? URL {
            visited += 1
            if visited > maxVisited { return (out, true) }
            let values = try? item.resourceValues(forKeys: Set(keys))
            let name = item.lastPathComponent
            if values?.isDirectory == true {
                if skipDirs.contains(name) || name.hasPrefix(".") {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values?.isRegularFile == true {
                out.append(item)
            }
        }
        return (out, false)
    }

    /// Converts a glob (supporting `*`, `?`, `**`) into an anchored regex.
    static func regexPattern(fromGlob glob: String) -> String {
        var out = "^"
        var i = glob.startIndex
        while i < glob.endIndex {
            let ch = glob[i]
            if ch == "*" {
                let next = glob.index(after: i)
                if next < glob.endIndex, glob[next] == "*" {
                    let afterNext = glob.index(after: next)
                    if afterNext < glob.endIndex, glob[afterNext] == "/" {
                        out += "(?:.*/)?"          // "**/" — any depth incl. none
                        i = glob.index(after: afterNext)
                        continue
                    }
                    out += ".*"                     // trailing "**"
                    i = afterNext
                    continue
                }
                out += "[^/]*"
            } else if ch == "?" {
                out += "[^/]"
            } else if "\\^$.|+()[]{}".contains(ch) {
                out += "\\" + String(ch)
            } else {
                out += String(ch)
            }
            i = glob.index(after: i)
        }
        return out + "$"
    }

    static func relativePath(of url: URL, under base: URL) -> String {
        let p = url.standardizedFileURL.path
        let b = base.standardizedFileURL.path
        if p.hasPrefix(b + "/") { return String(p.dropFirst(b.count + 1)) }
        return p
    }

    /// True when the first KB contains a NUL byte.
    static func isBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        return head.contains(0)
    }
}

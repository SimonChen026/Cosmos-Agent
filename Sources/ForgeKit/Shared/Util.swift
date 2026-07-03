import Foundation

enum Util {
    /// Resolves a user/model-supplied path: expands `~`, resolves relative
    /// paths against the workspace root.
    static func resolvePath(_ path: String, workspace: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return workspace.appendingPathComponent(expanded).standardizedFileURL
    }

    /// Shortens an absolute path for display (workspace-relative or ~-relative).
    static func displayPath(_ url: URL, workspace: URL) -> String {
        let p = url.standardizedFileURL.path
        let w = workspace.standardizedFileURL.path
        if p == w { return "." }
        if p.hasPrefix(w + "/") { return String(p.dropFirst(w.count + 1)) }
        let home = NSHomeDirectory()
        if p.hasPrefix(home + "/") { return "~/" + p.dropFirst(home.count + 1) }
        return p
    }

    /// Truncates text destined for the model, appending an explicit marker so
    /// the model knows content was cut.
    static func truncateForModel(_ text: String, maxChars: Int = 30_000) -> String {
        guard text.count > maxChars else { return text }
        let head = String(text.prefix(maxChars))
        return head + "\n…[truncated \(text.count - maxChars) of \(text.count) characters]"
    }

    /// Cheap token estimate (≈3 bytes per token — deliberately conservative).
    static func estimateTokens(_ text: String) -> Int {
        max(1, text.utf8.count / 3)
    }

    static func estimateTokens(_ messages: [ChatMessage]) -> Int {
        var total = 0
        for m in messages {
            for b in m.blocks {
                switch b {
                case .text(let t): total += estimateTokens(t)
                case .thinking(let t, _): total += estimateTokens(t)
                case .toolUse(_, let name, let input):
                    total += estimateTokens(name) + estimateTokens(input.encodedString())
                case .toolResult(_, let content, _): total += estimateTokens(content)
                }
            }
            total += 8 // per-message overhead
        }
        return total
    }
}

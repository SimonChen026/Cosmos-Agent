import Foundation

/// Two-stage context compaction, applied before each API call.
///
/// Stage A (>50% of budget): the content of tool_result blocks older than
/// the last `keepRecent` messages is cleared. Stage B (>80% after A):
/// everything between the first user message and the recent window is
/// replaced with one summary message. Cuts happen only at message
/// boundaries that keep every tool_use paired with its tool_result.
enum Compaction {
    static let clearedMarker = "[old tool output cleared]"

    static func compact(
        _ messages: [ChatMessage],
        config: AgentConfig,
        keepRecent: Int = 10,
        summarize: (String) async -> String?
    ) async -> (messages: [ChatMessage], note: String?) {
        let budget = config.contextTokenBudget
        var estimate = Util.estimateTokens(messages)
        guard estimate > budget / 2, messages.count > keepRecent + 2 else {
            return (messages, nil)
        }

        // Stage A — clear old tool outputs.
        var result = messages
        var cleared = 0
        let cutoff = max(0, result.count - keepRecent)
        for i in 0..<cutoff {
            var changed = false
            let blocks = result[i].blocks.map { block -> ContentBlock in
                if case .toolResult(let id, let content, let isError) = block,
                   content.count > 200, content != clearedMarker {
                    changed = true
                    cleared += 1
                    return .toolResult(toolUseId: id, content: clearedMarker, isError: isError)
                }
                return block
            }
            if changed { result[i].blocks = blocks }
        }
        var note: String? = cleared > 0
            ? "Compacted context: cleared \(cleared) old tool output\(cleared == 1 ? "" : "s")."
            : nil

        // Stage B — summarize the middle.
        estimate = Util.estimateTokens(result)
        if estimate > budget * 8 / 10, result.count > keepRecent + 2 {
            var start = result.count - keepRecent
            // Never let the window open on a tool_result carrier — pull its
            // tool_use partner (the preceding assistant message) in too.
            while start > 1, result[start].blocks.contains(where: isToolResult) {
                start -= 1
            }
            if start > 1 {
                let head = result[0]
                let middle = Array(result[1..<start])
                let tail = Array(result[start...])
                let summary = await summarize(digest(of: middle)) ?? mechanicalSummary(of: middle)
                let summaryMessage = ChatMessage(
                    role: .user,
                    blocks: [.text("[Earlier conversation summary]\n" + summary)]
                )
                result = [head, summaryMessage] + tail
                note = "Compacted context: summarized \(middle.count) earlier messages."
            }
        }
        return (result, note)
    }

    private static func isToolResult(_ block: ContentBlock) -> Bool {
        if case .toolResult = block { return true }
        return false
    }

    /// Plain-text digest of the middle segment, fed to the summarizer model.
    static func digest(of messages: [ChatMessage], maxChars: Int = 12_000) -> String {
        var lines: [String] = []
        for message in messages {
            for block in message.blocks {
                switch block {
                case .text(let text):
                    lines.append("[\(message.role.rawValue)] \(text.prefix(300))")
                case .thinking:
                    break
                case .toolUse(_, let name, let input):
                    lines.append("[tool] \(name)(\(input.encodedString().prefix(120)))")
                case .toolResult(_, let content, let isError):
                    lines.append("[result\(isError ? " ERROR" : "")] \(content.prefix(150))")
                }
            }
        }
        var text = lines.joined(separator: "\n")
        if text.count > maxChars {
            text = String(text.prefix(maxChars)) + "\n…(digest truncated)"
        }
        return text
    }

    /// Offline fallback when the summary API call fails.
    static func mechanicalSummary(of messages: [ChatMessage], maxLines: Int = 40) -> String {
        var lines: [String] = []
        for message in messages {
            for block in message.blocks {
                switch block {
                case .text(let text) where !text.isEmpty:
                    lines.append("- [\(message.role.rawValue)] \(text.prefix(120))")
                case .toolUse(_, let name, let input):
                    lines.append("- ran \(name)(\(input.encodedString().prefix(80)))")
                default:
                    break
                }
            }
        }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            lines.append("- …(more omitted)")
        }
        return lines.joined(separator: "\n")
    }
}

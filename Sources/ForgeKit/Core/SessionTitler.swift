import Foundation

/// Generates a short, descriptive session title via a cheap one-shot call
/// to the user's fastest configured model — replaces the old "first 48
/// characters of the first message" heuristic, which often produced a
/// title that was just a truncated sentence rather than a real summary.
enum SessionTitler {
    private struct DenyAllBroker: ApprovalBroker {
        func requestApproval(toolName: String, summary: String, input: JSONValue) async -> ApprovalDecision {
            .deny
        }
    }

    /// `exchange` is the first user message plus the first assistant reply
    /// (plain text only). Returns nil on any failure or unusable output so
    /// the caller can just keep the existing title rather than replace it
    /// with junk.
    static func summarize(exchange: String, judge: Provider, engine: any AgentEngineProtocol) async -> String? {
        var config = AgentConfig()
        config.apiKey = judge.apiKey
        config.model = judge.model
        config.providerKind = judge.kind
        config.baseURL = judge.baseURL
        config.temperature = judge.temperature
        config.topP = judge.topP
        config.maxTokens = 20
        config.maxTurns = 1
        config.thinkingMode = "off"

        let prompt = """
        Summarize this conversation's topic as a short session title, 3-6 words, no quotes, no trailing punctuation, same language as the conversation. Reply with ONLY the title, nothing else.

        \(exchange)
        """
        let request = AgentRunRequest(
            messages: [ChatMessage(role: .user, blocks: [.text(prompt)])],
            systemPrompt: "You write short, specific chat titles. Output only the title text, no quotes, no punctuation at the end, no preamble.",
            config: config,
            tools: [],
            session: ToolSessionState(),
            providers: []
        )

        var reply = ""
        for await event in engine.run(request, approval: DenyAllBroker()) {
            if case .runFinished(let messages, _) = event {
                reply = messages.last(where: { $0.role == .assistant })?.plainText ?? ""
            }
        }

        let cleaned = reply
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.。!！"))
        guard !cleaned.isEmpty, cleaned.count <= 80 else { return nil }
        return String(cleaned.prefix(60))
    }
}

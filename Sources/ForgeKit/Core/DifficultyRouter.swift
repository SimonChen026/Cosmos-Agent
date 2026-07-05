import Foundation

/// LLM-judge difficulty classifier: makes a cheap classification call
/// through the weakest configured model to decide which provider tier
/// should handle the real turn, and whether the request looks like
/// independent sub-tasks worth delegating to the agent tool.
enum DifficultyRouter {

    /// Trivial approval broker for the classification call: it never
    /// requests tools (the judge request carries none), so this is never
    /// actually invoked.
    private struct DenyAllBroker: ApprovalBroker {
        func requestApproval(toolName: String, summary: String, input: JSONValue) async -> ApprovalDecision {
            .deny
        }
    }

    /// Classifies `message` using `judge` (expected to be the fastest
    /// configured provider) via the same engine pipeline the main chat
    /// uses. Never throws and never blocks the caller indefinitely on a
    /// bad response — any failure or unparsable output falls back to
    /// ("balanced", false) so a slow/broken judge call can never stall or
    /// break the user's real turn.
    static func classify(message: String, judge: Provider, engine: any AgentEngineProtocol) async -> (tier: String, suggestsMultiAgent: Bool) {
        var config = AgentConfig()
        config.apiKey = judge.apiKey
        config.model = judge.model
        config.providerKind = judge.kind
        config.baseURL = judge.baseURL
        config.temperature = judge.temperature
        config.topP = judge.topP
        config.maxTokens = 60
        config.maxTurns = 1
        config.thinkingMode = "off"

        let prompt = """
        Classify the difficulty of this user request and whether it looks like independent sub-tasks that could be delegated to parallel agents. Reply with EXACTLY two lines, nothing else: line 1 is one word — fast, balanced, or strong; line 2 is yes or no.

        Request:
        \(message)
        """
        let request = AgentRunRequest(
            messages: [ChatMessage(role: .user, blocks: [.text(prompt)])],
            systemPrompt: "You are a fast triage classifier. Follow the requested two-line output format exactly, no extra words.",
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

        let lower = reply.lowercased()
        let tier: String
        if lower.contains("strong") { tier = "strong" }
        else if lower.contains("fast") { tier = "fast" }
        else if lower.contains("balanced") { tier = "balanced" }
        else { tier = "balanced" }
        let suggestsMultiAgent = lower.contains("yes")
        return (tier, suggestsMultiAgent)
    }

    /// Providers of the requested tier, falling back to the nearest tier
    /// when none is configured. Never returns empty for non-empty input.
    static func candidates(tier: String, from providers: [Provider]) -> [Provider] {
        let preference: [String]
        switch tier {
        case "fast": preference = ["fast", "balanced", "strong"]
        case "strong": preference = ["strong", "balanced", "fast"]
        default: preference = ["balanced", "strong", "fast"]
        }
        for wanted in preference {
            let matches = providers.filter { $0.tier == wanted }
            if !matches.isEmpty { return matches }
        }
        return providers
    }
}

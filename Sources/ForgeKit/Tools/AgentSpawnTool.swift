import Foundation

/// Spawns a subagent for a delegated subtask. Read-class, so the engine
/// runs several spawns from one turn concurrently — that is the automatic
/// division of labor. Each spawn rotates to the next configured provider,
/// spreading work across all pasted API keys. Subagents get every tool
/// except this one (no recursive spawning); their write/execute calls go
/// through the same approval UI as the main agent.
struct AgentSpawnTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "agent",
            description: "Delegate a self-contained subtask to a parallel subagent and get back its final report. For large tasks, split independent parts across several agent calls in ONE message — they run concurrently on different API keys. The subagent cannot see this conversation: include every needed detail in `task`.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "task": ["type": "string", "description": "Complete, self-contained instructions for the subagent."],
                    "context": ["type": "string", "description": "Optional extra background (file paths, constraints, findings so far)."],
                    "difficulty": ["type": "string", "enum": ["easy", "normal", "hard"], "description": "Routes the subtask to a matching provider tier (easy→fast, hard→strong). Default: normal."],
                ],
                "required": ["task"],
            ]
        )
    }

    var permissionClass: PermissionClass { .read }

    func summarize(input: JSONValue) -> String {
        let task = input["task"]?.stringValue ?? "?"
        return "agent: " + String(task.prefix(70))
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let task = input["task"]?.stringValue, !task.isEmpty else {
            return .error("agent: missing required parameter `task`.")
        }
        guard !context.providers.isEmpty else {
            return .error("agent: no API providers configured.")
        }
        guard let approval = context.approval else {
            return .error("agent: no approval broker available.")
        }
        // Tier routing: the caller declares subtask difficulty; the rotor
        // round-robins within the matching tier so all keys share the load.
        let difficulty = input["difficulty"]?.stringValue ?? "normal"
        let tier = ["easy": "fast", "hard": "strong"][difficulty] ?? "balanced"
        let pool = DifficultyRouter.candidates(tier: tier, from: context.providers)
        let provider = Self.rotor.next(from: pool)

        var config = AgentConfig()
        config.apiKey = provider.apiKey
        config.model = provider.model
        config.providerKind = provider.kind
        config.baseURL = provider.baseURL
        config.temperature = provider.temperature
        config.topP = provider.topP
        config.maxTokens = provider.maxTokens
        config.workspaceRoot = context.workspaceRoot.path
        config.maxTurns = 15

        var prompt = task
        if let extra = input["context"]?.stringValue, !extra.isEmpty {
            prompt += "\n\n<background>\n\(extra)\n</background>"
        }
        let systemPrompt = buildSystemPrompt(
            workspaceRoot: config.workspaceRoot, model: config.model
        ) + """


        You are a subagent handling one delegated subtask. Work autonomously, \
        then reply with a single final report: what you did, what you found, \
        and anything the delegating agent must know. No questions back.
        """

        let request = AgentRunRequest(
            messages: [ChatMessage(role: .user, blocks: [.text(prompt)])],
            systemPrompt: systemPrompt,
            config: config,
            tools: makeSubagentTools(),
            session: ToolSessionState(),   // fresh read-tracking per subagent
            providers: [])                 // subagents cannot spawn further

        let engine = AgentEngine()
        var final: (messages: [ChatMessage], reason: RunEndReason)?
        for await event in engine.run(request, approval: approval) {
            if case .runFinished(let messages, let reason) = event {
                final = (messages, reason)
            }
            if Task.isCancelled { engine.cancel() }
        }
        guard let final else {
            return .error("agent [\(provider.name)]: subagent produced no result.")
        }
        switch final.reason {
        case .failed(let message):
            return .error("agent [\(provider.name)] failed: \(message)")
        case .cancelled:
            return .error("agent [\(provider.name)]: interrupted.")
        case .completed, .maxTurnsReached:
            let report = final.messages.last(where: { $0.role == .assistant })?
                .plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let header = "[subagent on \(provider.name) · \(provider.model)]\n"
            return ToolOutput(content: Util.truncateForModel(
                header + (report.isEmpty ? "(subagent returned no text)" : report),
                maxChars: 20_000))
        }
    }

    // MARK: Provider rotation (round-robin across all keys)

    private static let rotor = Rotor()

    final class Rotor: @unchecked Sendable {
        private let lock = NSLock()
        private var counter = 0

        func next(from providers: [Provider]) -> Provider {
            lock.lock(); defer { lock.unlock() }
            let provider = providers[counter % providers.count]
            counter += 1
            return provider
        }
    }
}

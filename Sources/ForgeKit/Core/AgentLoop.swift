import Foundation

/// The agent loop: streams one Messages API call at a time, executes the
/// tools the model requests (reads concurrently, writes/executes serially
/// behind approval), feeds results back, and repeats until the model stops,
/// an error occurs, maxTurns is hit, or the run is cancelled.
final class AgentEngine: AgentEngineProtocol, @unchecked Sendable {
    private let transport: any APITransport
    private let lock = NSLock()
    private var runTask: Task<Void, Never>?
    private var cancelFlag = false

    init(transport: any APITransport = URLSessionTransport()) {
        self.transport = transport
    }

    func cancel() {
        lock.lock()
        cancelFlag = true
        let task = runTask
        lock.unlock()
        task?.cancel()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelFlag
    }

    func run(_ request: AgentRunRequest, approval: any ApprovalBroker) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            lock.lock()
            cancelFlag = false
            lock.unlock()
            let task = Task { [weak self] in
                if let self {
                    await self.runLoop(request, approval: approval) { continuation.yield($0) }
                }
                continuation.finish()
            }
            lock.lock()
            runTask = task
            lock.unlock()
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Main loop

    private struct ToolCall {
        var id: String
        var name: String
        var input: JSONValue
    }

    private func runLoop(_ request: AgentRunRequest, approval: any ApprovalBroker,
                         yield: @escaping (AgentEvent) -> Void) async {
        var messages = request.messages
        let config = request.config
        /// Assistant messages created during this run — their thinking
        /// blocks replay byte-identical; older thinking is stripped. Ids
        /// survive compaction, unlike indexes.
        var runMessageIds: Set<UUID> = []
        var turn = 0
        var thinkingEnabled = config.thinkingMode == "adaptive"
        var pendingMaxTokensRetry = false
        var maxTokensOverride: Int?
        let detector = LoopDetector()

        func finish(_ reason: RunEndReason) {
            yield(.runFinished(messages: messages, reason: reason))
        }

        while true {
            if isCancelled || Task.isCancelled { finish(.cancelled); return }
            if turn >= config.maxTurns { finish(.maxTurnsReached); return }
            turn += 1

            let (compacted, note) = await Compaction.compact(messages, config: config) { digest in
                await self.summarizeForCompaction(digest, config: config)
            }
            messages = compacted
            if let note { yield(.info(note)) }

            let outcome: TurnOutcome
            do {
                outcome = try await callWithRetries(
                    messages: messages, request: request, thinking: thinkingEnabled,
                    runMessageIds: runMessageIds, maxTokensOverride: maxTokensOverride,
                    yield: yield)
            } catch let error as APIError {
                // Models/accounts without adaptive thinking: drop it and redo.
                if case .http(400, let message) = error,
                   thinkingEnabled, message.lowercased().contains("thinking") {
                    thinkingEnabled = false
                    turn -= 1
                    continue
                }
                finish(isCancelled || Task.isCancelled ? .cancelled : .failed(error.description))
                return
            } catch is CancellationError {
                finish(.cancelled)
                return
            } catch {
                finish(isCancelled || Task.isCancelled
                    ? .cancelled : .failed(String(describing: error)))
                return
            }
            maxTokensOverride = nil

            switch outcome.stopReason {
            case "max_tokens":
                if !pendingMaxTokensRetry {
                    pendingMaxTokensRetry = true
                    maxTokensOverride = min(config.maxTokens * 4, 64_000)
                    yield(.info("Hit the output token limit — retrying with a larger budget."))
                    turn -= 1
                    continue   // the truncated message is discarded
                }
                let hasToolUse = outcome.message.blocks.contains {
                    if case .toolUse = $0 { return true } else { return false }
                }
                if hasToolUse {
                    finish(.failed("The response exceeded the output token budget twice; ask for something smaller."))
                    return
                }
                messages.append(outcome.message)
                runMessageIds.insert(outcome.message.id)
                finish(.completed)
                return

            case "tool_use":
                pendingMaxTokensRetry = false
                messages.append(outcome.message)
                runMessageIds.insert(outcome.message.id)
                let calls = outcome.message.blocks.compactMap { block -> ToolCall? in
                    if case .toolUse(let id, let name, let input) = block {
                        return ToolCall(id: id, name: name, input: input)
                    }
                    return nil
                }
                guard !calls.isEmpty else { finish(.completed); return }
                let results = await executeTools(
                    calls, request: request, approval: approval,
                    detector: detector, yield: yield)
                messages.append(ChatMessage(role: .user, blocks: results))
                if isCancelled || Task.isCancelled { finish(.cancelled); return }

            case "pause_turn":
                pendingMaxTokensRetry = false
                messages.append(outcome.message)
                runMessageIds.insert(outcome.message.id)

            default: // end_turn, refusal, stop_sequence
                pendingMaxTokensRetry = false
                if !outcome.message.blocks.isEmpty {
                    messages.append(outcome.message)
                    runMessageIds.insert(outcome.message.id)
                }
                finish(.completed)
                return
            }
        }
    }

    // MARK: - One API call

    private func callWithRetries(messages: [ChatMessage], request: AgentRunRequest,
                                 thinking: Bool, runMessageIds: Set<UUID>, maxTokensOverride: Int?,
                                 yield: @escaping (AgentEvent) -> Void) async throws -> TurnOutcome {
        var attempt = 1
        while true {
            do {
                return try await streamOnce(
                    messages: messages, request: request, thinking: thinking,
                    runMessageIds: runMessageIds, maxTokensOverride: maxTokensOverride,
                    yield: yield)
            } catch let error as APIError where error.isRetryable && attempt < 4 {
                let delay = 1 << (attempt - 1)
                yield(.info("\(error.shortLabel) — retrying in \(delay)s (attempt \(attempt + 1)/4)"))
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                attempt += 1
            }
        }
    }

    private func streamOnce(messages: [ChatMessage], request: AgentRunRequest,
                            thinking: Bool, runMessageIds: Set<UUID>, maxTokensOverride: Int?,
                            yield: @escaping (AgentEvent) -> Void) async throws -> TurnOutcome {
        let config = request.config
        let wire: WireRequest
        let collector: any StreamCollecting
        if config.providerKind == "openai" {
            let body = OpenAIRequestBuilder.body(
                messages: messages, systemPrompt: request.systemPrompt, config: config,
                tools: request.tools, maxTokensOverride: maxTokensOverride)
            wire = .openAI(baseURL: config.baseURL, apiKey: config.apiKey, body: body)
            collector = OpenAIStreamCollector(tools: request.tools, yield: yield)
        } else {
            let body = RequestBuilder.body(
                messages: messages, systemPrompt: request.systemPrompt, config: config,
                tools: request.tools, thinking: thinking, runMessageIds: runMessageIds,
                maxTokensOverride: maxTokensOverride)
            wire = .anthropic(baseURL: config.baseURL, apiKey: config.apiKey, body: body)
            collector = StreamCollector(tools: request.tools, yield: yield)
        }
        let stream = try await transport.send(wire)
        let parser = SSEParser()
        for try await chunk in stream {
            for event in parser.feed(chunk) {
                try collector.process(event)
            }
        }
        for event in parser.flush() {
            try collector.process(event)
        }
        return try collector.finishTurn()
    }

    // MARK: - Tool execution

    private func executeTools(_ calls: [ToolCall], request: AgentRunRequest,
                              approval: any ApprovalBroker, detector: LoopDetector,
                              yield: @escaping (AgentEvent) -> Void) async -> [ContentBlock] {
        let toolsByName = Dictionary(request.tools.map { ($0.spec.name, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let workspace = URL(fileURLWithPath:
            (request.config.workspaceRoot as NSString).expandingTildeInPath)
        let context = ToolContext(workspaceRoot: workspace, session: request.session,
                                  approval: approval, providers: request.providers)
        var outputs = [ToolOutput?](repeating: nil, count: calls.count)

        // Read-class calls run concurrently; results keep block order.
        await withTaskGroup(of: (Int, ToolOutput).self) { group in
            for (i, call) in calls.enumerated() {
                guard let tool = toolsByName[call.name], tool.permissionClass == .read else {
                    continue
                }
                group.addTask {
                    (i, await tool.execute(input: call.input, context: context))
                }
            }
            for await (i, output) in group {
                outputs[i] = output
            }
        }

        // Write/execute (and unknown) calls run serially, behind approval.
        for (i, call) in calls.enumerated() where outputs[i] == nil {
            if isCancelled || Task.isCancelled {
                outputs[i] = .error("Interrupted by user.")
                continue
            }
            guard let tool = toolsByName[call.name] else {
                outputs[i] = .error("Unknown tool: \(call.name)")
                continue
            }
            let decision = await approval.requestApproval(
                toolName: call.name,
                summary: tool.summarize(input: call.input),
                input: call.input)
            if isCancelled || Task.isCancelled {
                outputs[i] = .error("Interrupted by user.")
                continue
            }
            if case .deny = decision {
                outputs[i] = .error("The user denied this tool call.")
                continue
            }
            outputs[i] = await tool.execute(input: call.input, context: context)
        }

        var blocks: [ContentBlock] = []
        for (i, call) in calls.enumerated() {
            var output = outputs[i] ?? .error("Tool did not produce a result.")
            if let warning = detector.check(name: call.name, input: call.input) {
                output.content += warning
            }
            yield(.toolResult(toolUseId: call.id, name: call.name, output: output))
            blocks.append(.toolResult(
                toolUseId: call.id, content: output.content, isError: output.isError))
        }
        return blocks
    }

    // MARK: - Compaction summarizer (haiku, best-effort)

    private func summarizeForCompaction(_ digest: String, config: AgentConfig) async -> String? {
        let prompt = """
        Summarize this coding-agent conversation segment for context compaction. Capture: \
        decisions made, files created or modified, commands run, unresolved errors, and \
        the user's current goal. Be terse; at most 600 tokens. Output only the summary.

        <segment>
        \(digest)
        </segment>
        """
        let summaryMessages = [ChatMessage(role: .user, blocks: [.text(prompt)])]
        let system = "You summarize coding sessions accurately and tersely."
        let wire: WireRequest
        if config.providerKind == "openai" {
            let body = OpenAIRequestBuilder.body(
                messages: summaryMessages, systemPrompt: system, config: config,
                tools: [], maxTokensOverride: 800)
            wire = .openAI(baseURL: config.baseURL, apiKey: config.apiKey, body: body)
        } else {
            let body = RequestBuilder.body(
                messages: summaryMessages, systemPrompt: system,
                config: config, tools: [], thinking: false, runMessageIds: [],
                maxTokensOverride: 800, modelOverride: "claude-haiku-4-5-20251001",
                cache: false)
            wire = .anthropic(baseURL: config.baseURL, apiKey: config.apiKey, body: body)
        }
        do {
            let stream = try await transport.send(wire)
            let parser = SSEParser()
            let collector: any StreamCollecting = config.providerKind == "openai"
                ? OpenAIStreamCollector(tools: [], yield: { _ in })
                : StreamCollector(tools: [], yield: { _ in })
            for try await chunk in stream {
                for event in parser.feed(chunk) {
                    try collector.process(event)
                }
            }
            for event in parser.flush() {
                try collector.process(event)
            }
            let text = try collector.finishTurn().message.plainText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}

// MARK: - Turn outcome

struct TurnOutcome {
    var message: ChatMessage
    var stopReason: String
}

/// One API call's stream state machine, per provider wire format.
protocol StreamCollecting: AnyObject {
    func process(_ event: SSEEvent) throws
    func finishTurn() throws -> TurnOutcome
}

// MARK: - Repeated-call detection

private final class LoopDetector {
    private var lastSignature = ""
    private var repeats = 0

    /// Returns a warning once the same call has arrived 3+ times in a row.
    func check(name: String, input: JSONValue) -> String? {
        let signature = name + "|" + input.encodedString()
        if signature == lastSignature {
            repeats += 1
        } else {
            lastSignature = signature
            repeats = 1
        }
        return repeats >= 3
            ? "\n\n[warning] You appear to be repeating the same call. Change strategy."
            : nil
    }
}

// MARK: - Stream state machine

/// Folds one Anthropic API call's SSE events into content blocks, emitting
/// display events along the way. `tool_use` inputs accumulate as JSON
/// fragments and are parsed only at content_block_stop.
final class StreamCollector: StreamCollecting {
    private let messageId = UUID()
    private let yield: (AgentEvent) -> Void
    private let toolsByName: [String: any AgentTool]

    private enum Partial {
        case text(String)
        case thinking(text: String, signature: String)
        case toolUse(id: String, name: String, json: String)
        case ignored
    }

    private var partials: [Int: Partial] = [:]
    private var order: [Int] = []
    private var stopReason: String?
    private var started = false
    private var inputTokens = 0
    private var cacheReadTokens = 0
    private var outputTokens = 0

    init(tools: [any AgentTool], yield: @escaping (AgentEvent) -> Void) {
        self.yield = yield
        self.toolsByName = Dictionary(tools.map { ($0.spec.name, $0) },
                                      uniquingKeysWith: { first, _ in first })
    }

    func process(_ event: SSEEvent) throws {
        guard let json = try? JSONValue.parse(event.data) else { return }
        switch event.name {
        case "message_start":
            started = true
            yield(.messageStarted(id: messageId, role: .assistant))
            if let usage = json["message"]?["usage"] {
                inputTokens = (usage["input_tokens"]?.intValue ?? 0)
                    + (usage["cache_creation_input_tokens"]?.intValue ?? 0)
                cacheReadTokens = usage["cache_read_input_tokens"]?.intValue ?? 0
            }

        case "content_block_start":
            guard let index = json["index"]?.intValue,
                  let type = json["content_block"]?["type"]?.stringValue else { return }
            order.append(index)
            switch type {
            case "text":
                partials[index] = .text("")
            case "thinking":
                partials[index] = .thinking(text: "", signature: "")
            case "tool_use":
                let id = json["content_block"]?["id"]?.stringValue ?? UUID().uuidString
                let name = json["content_block"]?["name"]?.stringValue ?? "unknown"
                partials[index] = .toolUse(id: id, name: name, json: "")
                yield(.toolCallStarted(messageId: messageId, toolUseId: id, name: name))
            default:
                partials[index] = .ignored   // redacted_thinking and friends
            }

        case "content_block_delta":
            guard let index = json["index"]?.intValue, let delta = json["delta"] else { return }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let text = delta["text"]?.stringValue ?? ""
                if case .text(let existing)? = partials[index] {
                    partials[index] = .text(existing + text)
                    yield(.textDelta(messageId: messageId, delta: text))
                }
            case "thinking_delta":
                let text = delta["thinking"]?.stringValue ?? ""
                if case .thinking(let existing, let signature)? = partials[index] {
                    partials[index] = .thinking(text: existing + text, signature: signature)
                    yield(.thinkingDelta(messageId: messageId, delta: text))
                }
            case "input_json_delta":
                let fragment = delta["partial_json"]?.stringValue ?? ""
                if case .toolUse(let id, let name, let json0)? = partials[index] {
                    partials[index] = .toolUse(id: id, name: name, json: json0 + fragment)
                }
            case "signature_delta":
                let fragment = delta["signature"]?.stringValue ?? ""
                if case .thinking(let text, let existing)? = partials[index] {
                    partials[index] = .thinking(text: text, signature: existing + fragment)
                }
            default:
                break
            }

        case "content_block_stop":
            guard let index = json["index"]?.intValue else { return }
            if case .toolUse(let id, let name, let accumulated)? = partials[index] {
                let input = Self.parseInput(accumulated)
                let summary = toolsByName[name]?.summarize(input: input) ?? name
                yield(.toolCallReady(messageId: messageId, toolUseId: id, name: name,
                                     input: input, summary: summary))
            }

        case "message_delta":
            if let reason = json["delta"]?["stop_reason"]?.stringValue {
                stopReason = reason
            }
            if let output = json["usage"]?["output_tokens"]?.intValue {
                outputTokens = output
            }

        case "error":
            let type = json["error"]?["type"]?.stringValue ?? "api_error"
            let message = json["error"]?["message"]?.stringValue ?? "unknown stream error"
            throw APIError.streamError(type: type, message: message)

        default: // message_stop, ping, unknown future events
            break
        }
    }

    func finishTurn() throws -> TurnOutcome {
        guard started else {
            throw APIError.badResponse("stream ended before message_start")
        }
        yield(.usage(inputTokens: inputTokens, outputTokens: outputTokens,
                     cacheReadTokens: cacheReadTokens))
        var blocks: [ContentBlock] = []
        for index in order {
            switch partials[index] {
            case .text(let text):
                if !text.isEmpty { blocks.append(.text(text)) }
            case .thinking(let text, let signature):
                if !text.isEmpty {
                    blocks.append(.thinking(text, signature: signature.isEmpty ? nil : signature))
                }
            case .toolUse(let id, let name, let json):
                blocks.append(.toolUse(id: id, name: name, input: Self.parseInput(json)))
            case .ignored, nil:
                break
            }
        }
        return TurnOutcome(
            message: ChatMessage(id: messageId, role: .assistant, blocks: blocks),
            stopReason: stopReason ?? "end_turn")
    }

    private static func parseInput(_ accumulated: String) -> JSONValue {
        (try? JSONValue.parse(accumulated.isEmpty ? "{}" : accumulated)) ?? .object([:])
    }
}

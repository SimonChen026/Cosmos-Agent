import Foundation
@testable import ForgeKit

// MARK: - Wire helpers

private func sse(_ name: String, _ json: String) -> String {
    "event: \(name)\ndata: \(json)\n\n"
}

private func textTurn(_ text: String, stop: String = "end_turn") -> [String] {
    [
        sse("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":2,"cache_creation_input_tokens":0}}}"#),
        sse("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
        sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}"#),
        sse("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        sse("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(stop)"},"usage":{"output_tokens":5}}"#),
        sse("message_stop", #"{"type":"message_stop"}"#),
    ]
}

private func toolUseTurn(id: String, name: String, fragments: [String]) -> [String] {
    var events = [
        sse("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":20,"cache_read_input_tokens":0}}}"#),
        sse("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}}"#),
    ]
    for fragment in fragments {
        let escaped = fragment
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        events.append(sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\#(escaped)"}}"#))
    }
    events.append(sse("content_block_stop", #"{"type":"content_block_stop","index":0}"#))
    events.append(sse("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":15}}"#))
    events.append(sse("message_stop", #"{"type":"message_stop"}"#))
    return events
}

// MARK: - Mock transport / tools / brokers

enum MockStep {
    case events([String])
    case failure(APIError)
}

final class MockTransport: APITransport, @unchecked Sendable {
    private let lock = NSLock()
    private let steps: [MockStep]
    private var recorded: [Data] = []

    init(_ steps: [MockStep]) { self.steps = steps }

    var bodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func body(at index: Int) -> JSONValue? {
        let all = bodies
        guard index < all.count else { return nil }
        return try? JSONValue.parse(all[index])
    }

    private func record(_ body: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        recorded.append(body)
        return recorded.count - 1
    }

    func send(_ request: WireRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let index = record(request.body)
        guard let step = index < steps.count ? steps[index] : steps.last else {
            throw APIError.badResponse("mock transport has no steps")
        }
        switch step {
        case .failure(let error):
            throw error
        case .events(let events):
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(Data(event.utf8)) }
                continuation.finish()
            }
        }
    }
}

final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [JSONValue] = []

    func add(_ value: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        stored.append(value)
    }

    var inputs: [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

struct ProbeTool: AgentTool {
    let box: ProbeBox
    let permission: PermissionClass

    var spec: ToolSpec {
        ToolSpec(name: "probe", description: "test probe", inputSchema: ["type": "object"])
    }
    var permissionClass: PermissionClass { permission }

    func summarize(input: JSONValue) -> String { "probe" }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        box.add(input)
        return ToolOutput(content: "probe-ok")
    }
}

struct AllowBroker: ApprovalBroker {
    func requestApproval(toolName: String, summary: String, input: JSONValue) async -> ApprovalDecision {
        .allowOnce
    }
}

struct DenyBroker: ApprovalBroker {
    func requestApproval(toolName: String, summary: String, input: JSONValue) async -> ApprovalDecision {
        .deny
    }
}

/// Hangs long enough that a cancellation always lands first.
struct SlowBroker: ApprovalBroker {
    func requestApproval(toolName: String, summary: String, input: JSONValue) async -> ApprovalDecision {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        return .allowOnce
    }
}

// MARK: - Run helpers

private func runEngine(
    steps: [MockStep],
    tools: [any AgentTool],
    broker: any ApprovalBroker = AllowBroker(),
    configure: (inout AgentConfig) -> Void = { _ in }
) async -> (events: [AgentEvent], transport: MockTransport) {
    let transport = MockTransport(steps)
    let engine = AgentEngine(transport: transport)
    var config = AgentConfig()
    config.apiKey = "test-key"
    config.workspaceRoot = FileManager.default.temporaryDirectory.path
    configure(&config)
    let request = AgentRunRequest(
        messages: [ChatMessage(role: .user, blocks: [.text("hi")])],
        systemPrompt: "test system prompt",
        config: config, tools: tools, session: ToolSessionState())
    var events: [AgentEvent] = []
    for await event in engine.run(request, approval: broker) {
        events.append(event)
    }
    return (events, transport)
}

private func finished(_ events: [AgentEvent]) -> (messages: [ChatMessage], reason: RunEndReason)? {
    for event in events {
        if case .runFinished(let messages, let reason) = event { return (messages, reason) }
    }
    return nil
}

private func toolResults(in messages: [ChatMessage]) -> [(id: String, content: String, isError: Bool)] {
    var out: [(String, String, Bool)] = []
    for message in messages {
        for block in message.blocks {
            if case .toolResult(let id, let content, let isError) = block {
                out.append((id, content, isError))
            }
        }
    }
    return out
}

func pairsIntact(_ messages: [ChatMessage]) -> Bool {
    var toolUseIds = Set<String>()
    for message in messages {
        for block in message.blocks {
            if case .toolUse(let id, _, _) = block { toolUseIds.insert(id) }
        }
    }
    for message in messages {
        for block in message.blocks {
            if case .toolResult(let id, _, _) = block, !toolUseIds.contains(id) {
                return false
            }
        }
    }
    return true
}

// MARK: - Suite

func coreTests() async {

    // ---- SSE parser

    await test("SSE parser: chunks split mid-event") {
        let parser = SSEParser()
        let wire = "event: message_start\ndata: {\"a\":1}\n\nevent: ping\ndata: {}\n\n"
        let cut = wire.index(wire.startIndex, offsetBy: 21)
        var events = parser.feed(Data(wire[..<cut].utf8))
        events += parser.feed(Data(wire[cut...].utf8))
        expectEqual(events.count, 2)
        expectEqual(events.first?.name, "message_start")
        expectEqual(events.first?.data, "{\"a\":1}")
        expectEqual(events.last?.name, "ping")
    }

    await test("SSE parser: CRLF framing and comments") {
        let parser = SSEParser()
        let wire = ": comment\r\nevent: message_delta\r\ndata: {\"b\":2}\r\n\r\n"
        let events = parser.feed(Data(wire.utf8))
        expectEqual(events.count, 1)
        expectEqual(events.first?.name, "message_delta")
        expectEqual(events.first?.data, "{\"b\":2}")
    }

    await test("SSE parser: multi-line data joined, flush recovers tail") {
        let parser = SSEParser()
        var events = parser.feed(Data("data: line1\ndata: line2\n\n".utf8))
        expectEqual(events.count, 1)
        expectEqual(events.first?.data, "line1\nline2")
        events = parser.feed(Data("event: tail\ndata: {\"x\":9}".utf8))
        expect(events.isEmpty, "incomplete event must wait")
        let flushed = parser.flush()
        expectEqual(flushed.count, 1)
        expectEqual(flushed.first?.name, "tail")
    }

    // ---- Agent loop

    await test("loop: tool_use round trip") {
        let box = ProbeBox()
        let steps: [MockStep] = [
            .events(toolUseTurn(id: "tu_1", name: "probe", fragments: ["{\"va", "lue\": 42}"])),
            .events(textTurn("done")),
        ]
        let (events, transport) = await runEngine(steps: steps, tools: [ProbeTool(box: box, permission: .read)])

        expectEqual(box.inputs.count, 1)
        expectEqual(box.inputs.first?["value"]?.intValue, 42)

        guard let (messages, reason) = finished(events) else { return fail("no runFinished") }
        expectEqual(reason, .completed)
        expectEqual(messages.count, 4, "user, assistant(tool_use), user(tool_result), assistant(text)")
        expect(pairsIntact(messages))
        let results = toolResults(in: messages)
        expectEqual(results.count, 1)
        expectEqual(results.first?.id, "tu_1")
        expectEqual(results.first?.content, "probe-ok")

        expectEqual(transport.bodies.count, 2)
        let second = transport.body(at: 1)
        let sentMessages = second?["messages"]?.arrayValue ?? []
        let lastSent = sentMessages.last
        expectEqual(lastSent?["role"]?.stringValue, "user")
        expectEqual(lastSent?["content"]?.arrayValue?.first?["type"]?.stringValue, "tool_result")
        expectEqual(lastSent?["content"]?.arrayValue?.first?["tool_use_id"]?.stringValue, "tu_1")

        var sawReady = false
        for event in events {
            if case .toolCallReady(_, "tu_1", "probe", let input, _) = event {
                sawReady = true
                expectEqual(input["value"]?.intValue, 42)
            }
        }
        expect(sawReady, "expected toolCallReady with parsed input")
    }

    await test("loop: denial becomes is_error tool_result, run continues") {
        let box = ProbeBox()
        let steps: [MockStep] = [
            .events(toolUseTurn(id: "tu_d", name: "probe", fragments: ["{}"])),
            .events(textTurn("adapted")),
        ]
        let (events, _) = await runEngine(
            steps: steps, tools: [ProbeTool(box: box, permission: .write)], broker: DenyBroker())
        expectEqual(box.inputs.count, 0, "denied tool must not execute")
        guard let (messages, reason) = finished(events) else { return fail("no runFinished") }
        expectEqual(reason, .completed)
        let results = toolResults(in: messages)
        expectEqual(results.first?.isError, true)
        expect(results.first?.content.contains("denied") == true)
    }

    await test("loop: repeated identical calls get a warning") {
        let box = ProbeBox()
        var steps: [MockStep] = []
        for _ in 0..<3 {
            steps.append(.events(toolUseTurn(id: "tu_r", name: "probe", fragments: ["{\"q\": 1}"])))
        }
        steps.append(.events(textTurn("stopped repeating")))
        let (events, _) = await runEngine(steps: steps, tools: [ProbeTool(box: box, permission: .read)])
        guard let (messages, _) = finished(events) else { return fail("no runFinished") }
        let results = toolResults(in: messages)
        expectEqual(results.count, 3)
        expect(!results[0].content.contains("repeating"))
        expect(!results[1].content.contains("repeating"))
        expect(results[2].content.contains("repeating"), "third identical call should warn")
    }

    await test("loop: max_tokens retries once with larger budget, discards truncated turn") {
        let steps: [MockStep] = [
            .events(textTurn("partial", stop: "max_tokens")),
            .events(textTurn("full answer")),
        ]
        let (events, transport) = await runEngine(steps: steps, tools: [])
        expectEqual(transport.bodies.count, 2)
        expectEqual(transport.body(at: 0)?["max_tokens"]?.intValue, 16_384)
        expectEqual(transport.body(at: 1)?["max_tokens"]?.intValue, 64_000)
        guard let (messages, reason) = finished(events) else { return fail("no runFinished") }
        expectEqual(reason, .completed)
        let assistants = messages.filter { $0.role == .assistant }
        expectEqual(assistants.count, 1, "truncated assistant turn must be discarded")
        expectEqual(assistants.first?.plainText, "full answer")
    }

    await test("loop: overloaded stream error retries then succeeds") {
        let steps: [MockStep] = [
            .events([sse("error", #"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#)]),
            .events(textTurn("recovered")),
        ]
        let (events, transport) = await runEngine(steps: steps, tools: [])
        expectEqual(transport.bodies.count, 2)
        guard let (messages, reason) = finished(events) else { return fail("no runFinished") }
        expectEqual(reason, .completed)
        expectEqual(messages.last?.plainText, "recovered")
    }

    await test("loop: non-retryable HTTP error fails the run") {
        let steps: [MockStep] = [.failure(.http(status: 401, message: "invalid x-api-key"))]
        let (events, transport) = await runEngine(steps: steps, tools: [])
        expectEqual(transport.bodies.count, 1)
        guard let (_, reason) = finished(events) else { return fail("no runFinished") }
        if case .failed(let message) = reason {
            expect(message.contains("401"))
        } else {
            fail("expected .failed, got \(reason)")
        }
    }

    await test("loop: 400 mentioning thinking retries without thinking") {
        let steps: [MockStep] = [
            .failure(.http(status: 400, message: "thinking is not supported for this model")),
            .events(textTurn("ok")),
        ]
        let (events, transport) = await runEngine(steps: steps, tools: [])
        expectEqual(transport.bodies.count, 2)
        expect(transport.body(at: 0)?["thinking"] != nil, "first attempt sends thinking")
        expect(transport.body(at: 1)?["thinking"] == nil, "retry drops thinking")
        guard let (_, reason) = finished(events) else { return fail("no runFinished") }
        expectEqual(reason, .completed)
    }

    await test("loop: cancellation during approval synthesizes interrupted result") {
        let box = ProbeBox()
        let transport = MockTransport([
            .events(toolUseTurn(id: "tu_c", name: "probe", fragments: ["{}"])),
        ])
        let engine = AgentEngine(transport: transport)
        var config = AgentConfig()
        config.apiKey = "k"
        let request = AgentRunRequest(
            messages: [ChatMessage(role: .user, blocks: [.text("go")])],
            systemPrompt: "s", config: config,
            tools: [ProbeTool(box: box, permission: .write)],
            session: ToolSessionState())
        let collector = Task { () -> [AgentEvent] in
            var collected: [AgentEvent] = []
            for await event in engine.run(request, approval: SlowBroker()) {
                collected.append(event)
            }
            return collected
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        engine.cancel()
        let events = await collector.value
        expectEqual(box.inputs.count, 0, "tool must not run after cancel")
        guard let (messages, reason) = finished(events) else { return fail("no runFinished") }
        expectEqual(reason, .cancelled)
        expect(pairsIntact(messages))
        let results = toolResults(in: messages)
        expectEqual(results.count, 1)
        expect(results.first?.content.contains("Interrupted") == true)
    }

    await test("loop: usage events surface token counts") {
        let (events, _) = await runEngine(steps: [.events(textTurn("hi"))], tools: [])
        var saw = false
        for event in events {
            if case .usage(let input, let output, let cacheRead) = event {
                saw = true
                expectEqual(input, 10)
                expectEqual(output, 5)
                expectEqual(cacheRead, 2)
            }
        }
        expect(saw, "expected a usage event")
    }

    // ---- Request building

    await test("request body: structure, cache breakpoints, tools") {
        let body = RequestBuilder.body(
            messages: [ChatMessage(role: .user, blocks: [.text("hello")])],
            systemPrompt: "SYS", config: AgentConfig(), tools: makeDefaultTools(),
            thinking: true, runMessageIds: [])
        guard let json = try? JSONValue.parse(body) else { return fail("body not JSON") }
        expectEqual(json["stream"]?.boolValue, true)
        expectEqual(json["thinking"]?["type"]?.stringValue, "adaptive")
        expectEqual(json["tools"]?.arrayValue?.count, 14)
        let system = json["system"]?.arrayValue?.first
        expectEqual(system?["cache_control"]?["type"]?.stringValue, "ephemeral")
        let lastBlock = json["messages"]?.arrayValue?.last?["content"]?.arrayValue?.last
        expectEqual(lastBlock?["cache_control"]?["type"]?.stringValue, "ephemeral")
    }

    await test("request body: historical thinking stripped, unsigned dropped") {
        let messages = [
            ChatMessage(role: .user, blocks: [.text("q1")]),
            ChatMessage(role: .assistant, blocks: [
                .thinking("old thought", signature: "sig"), .text("a1"),
            ]),
            ChatMessage(role: .user, blocks: [.text("q2")]),
            ChatMessage(role: .assistant, blocks: [
                .thinking("new thought", signature: "sig2"),
                .thinking("unsigned", signature: nil),
                .text("a2"),
            ]),
        ]
        // Only the current run's assistant message keeps signed thinking.
        let body = RequestBuilder.body(
            messages: messages, systemPrompt: "s", config: AgentConfig(), tools: [],
            thinking: true, runMessageIds: [messages[3].id])
        guard let json = try? JSONValue.parse(body) else { return fail("body not JSON") }
        let sent = json["messages"]?.arrayValue ?? []
        let oldAssistant = sent[1]["content"]?.arrayValue ?? []
        expectEqual(oldAssistant.count, 1, "historical thinking must be stripped")
        let newAssistant = sent[3]["content"]?.arrayValue ?? []
        expectEqual(newAssistant.count, 2, "signed thinking kept, unsigned dropped")
        expectEqual(newAssistant.first?["type"]?.stringValue, "thinking")
    }

    await test("request body: consecutive same-role messages merged") {
        let messages = [
            ChatMessage(role: .user, blocks: [.text("first")]),
            ChatMessage(role: .user, blocks: [.text("[Earlier conversation summary]\nS")]),
            ChatMessage(role: .assistant, blocks: [.text("reply")]),
        ]
        let body = RequestBuilder.body(
            messages: messages, systemPrompt: "s", config: AgentConfig(), tools: [],
            thinking: false, runMessageIds: [])
        guard let json = try? JSONValue.parse(body) else { return fail("body not JSON") }
        let sent = json["messages"]?.arrayValue ?? []
        expectEqual(sent.count, 2, "two user turns must merge into one")
        expectEqual(sent.first?["content"]?.arrayValue?.count, 2)
        expectEqual(sent.last?["role"]?.stringValue, "assistant")
    }

    // ---- Difficulty routing

    await test("router: classify parses tier and multi-agent signal") {
        let transport = MockTransport([.events(textTurn(#"strong\nyes"#))])
        let engine = AgentEngine(transport: transport)
        let judge = Provider(name: "j", kind: "anthropic", baseURL: "u", model: "m",
                             apiKey: "k", tier: "fast")
        let result = await DifficultyRouter.classify(message: "refactor this", judge: judge, engine: engine)
        expectEqual(result.tier, "strong")
        expect(result.suggestsMultiAgent, "expected suggestsMultiAgent to be true")
    }

    await test("router: classify falls back to balanced on garbage output") {
        let transport = MockTransport([.events(textTurn("¯\\_(ツ)_/¯"))])
        let engine = AgentEngine(transport: transport)
        let judge = Provider(name: "j", kind: "anthropic", baseURL: "u", model: "m",
                             apiKey: "k", tier: "fast")
        let result = await DifficultyRouter.classify(message: "hi", judge: judge, engine: engine)
        expectEqual(result.tier, "balanced")
        expect(!result.suggestsMultiAgent, "expected suggestsMultiAgent to be false")
    }

    await test("router: classify falls back to balanced when the call fails") {
        let transport = MockTransport([.failure(.badResponse("boom"))])
        let engine = AgentEngine(transport: transport)
        let judge = Provider(name: "j", kind: "anthropic", baseURL: "u", model: "m",
                             apiKey: "k", tier: "fast")
        let result = await DifficultyRouter.classify(message: "hi", judge: judge, engine: engine)
        expectEqual(result.tier, "balanced")
        expect(!result.suggestsMultiAgent, "expected suggestsMultiAgent to be false")
    }

    await test("router: tier candidates with fallback") {
        let fast = Provider(name: "f", kind: "openai", baseURL: "u", model: "m",
                            apiKey: "k1", tier: "fast")
        let strong = Provider(name: "s", kind: "anthropic", baseURL: "u", model: "m",
                              apiKey: "k2", tier: "strong")
        let both = [fast, strong]
        expectEqual(DifficultyRouter.candidates(tier: "fast", from: both).first?.name, "f")
        expectEqual(DifficultyRouter.candidates(tier: "strong", from: both).first?.name, "s")
        // No balanced provider → strong is the nearest fallback.
        expectEqual(DifficultyRouter.candidates(tier: "balanced", from: both).first?.name, "s")
        expectEqual(DifficultyRouter.candidates(tier: "balanced", from: [fast]).first?.name, "f")
    }

    await test("provider: key detection with URL/model overrides") {
        let anthropic = Provider.detect(fromKey: "sk-ant-abc123")
        expectEqual(anthropic.kind, "anthropic")
        expectEqual(anthropic.baseURL, "https://api.anthropic.com")
        let deepseek = Provider.detect(fromKey: "sk-zz9900",
                                       baseURL: "https://api.deepseek.com/",
                                       model: "deepseek-chat")
        expectEqual(deepseek.kind, "openai")
        expectEqual(deepseek.baseURL, "https://api.deepseek.com")
        expectEqual(deepseek.model, "deepseek-chat")
        expectEqual(deepseek.name, "deepseek.com")
        // Old provider blobs without tuning fields still decode.
        let legacyJSON = #"[{"id":"11111111-1111-1111-1111-111111111111","name":"n","kind":"openai","baseURL":"u","model":"m","apiKey":"k"}]"#
        let decoded = try JSONDecoder().decode([Provider].self, from: Data(legacyJSON.utf8))
        expectEqual(decoded.first?.tier, "balanced")
        expectEqual(decoded.first?.temperature, 1.0)
    }

    await test("provider: supportsVision heuristic") {
        let anthropic = Provider(name: "n", kind: "anthropic", baseURL: "u",
                                  model: "whatever", apiKey: "k")
        expect(anthropic.supportsVision)
        let gpt4o = Provider(name: "n", kind: "openai", baseURL: "u",
                              model: "gpt-4o-mini", apiKey: "k")
        expect(gpt4o.supportsVision)
        let deepseek = Provider(name: "n", kind: "openai", baseURL: "u",
                                 model: "deepseek-chat", apiKey: "k")
        expect(!deepseek.supportsVision)
    }

    await test("sampling: temperature/top_p reach both wire formats") {
        var config = AgentConfig()
        config.temperature = 1.6
        let anthropicBody = try JSONValue.parse(RequestBuilder.body(
            messages: [ChatMessage(role: .user, blocks: [.text("x")])],
            systemPrompt: "s", config: config, tools: [], thinking: false, runMessageIds: []))
        expectEqual(anthropicBody["temperature"]?.numberValue, 1.0, "anthropic clamps to 1")
        let openaiBody = try JSONValue.parse(OpenAIRequestBuilder.body(
            messages: [ChatMessage(role: .user, blocks: [.text("x")])],
            systemPrompt: "s", config: config, tools: []))
        expectEqual(openaiBody["temperature"]?.numberValue, 1.6)
        expect(openaiBody["top_p"] == nil, "top_p omitted at default 1.0")
        config.topP = 0.9
        let capped = try JSONValue.parse(RequestBuilder.body(
            messages: [ChatMessage(role: .user, blocks: [.text("x")])],
            systemPrompt: "s", config: config, tools: [], thinking: false, runMessageIds: []))
        expectEqual(capped["top_p"]?.numberValue, 0.9)
        expect(capped["temperature"] == nil, "anthropic sends one of temperature/top_p")
    }

    // ---- OpenAI wire format

    await test("openai: request mapping — system, tool_calls, role:tool") {
        let messages = [
            ChatMessage(role: .user, blocks: [.text("hi")]),
            ChatMessage(role: .assistant, blocks: [
                .thinking("never sent", signature: nil),
                .toolUse(id: "call_9", name: "probe", input: ["a": 1]),
            ]),
            ChatMessage(role: .user, blocks: [
                .toolResult(toolUseId: "call_9", content: "out", isError: true),
            ]),
        ]
        var config = AgentConfig()
        config.model = "gpt-4o"
        let body = OpenAIRequestBuilder.body(
            messages: messages, systemPrompt: "SYS", config: config, tools: makeDefaultTools())
        guard let json = try? JSONValue.parse(body) else { return fail("body not JSON") }
        expectEqual(json["stream"]?.boolValue, true)
        expectEqual(json["stream_options"]?["include_usage"]?.boolValue, true)
        expectEqual(json["tools"]?.arrayValue?.count, 14)
        expectEqual(json["tools"]?.arrayValue?.first?["type"]?.stringValue, "function")
        let sent = json["messages"]?.arrayValue ?? []
        expectEqual(sent.count, 4, "system, user, assistant, tool")
        expectEqual(sent[0]["role"]?.stringValue, "system")
        expectEqual(sent[1]["role"]?.stringValue, "user")
        let call = sent[2]["tool_calls"]?.arrayValue?.first
        expectEqual(call?["id"]?.stringValue, "call_9")
        expectEqual(call?["function"]?["name"]?.stringValue, "probe")
        expect(call?["function"]?["arguments"]?.stringValue?.contains("\"a\":1") == true)
        expect(sent[2]["content"] == nil, "thinking must not leak into content")
        expectEqual(sent[3]["role"]?.stringValue, "tool")
        expectEqual(sent[3]["tool_call_id"]?.stringValue, "call_9")
        expectEqual(sent[3]["content"]?.stringValue, "ERROR: out")
    }

    await test("openai: loop round trip with tool_calls stream") {
        func oai(_ json: String) -> String { "data: \(json)\n\n" }
        let toolTurn: [String] = [
            oai(#"{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"probe","arguments":""}}]},"finish_reason":null}]}"#),
            oai(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"value\": 7}"}}]},"finish_reason":null}]}"#),
            oai(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
            oai(#"{"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":4,"prompt_tokens_details":{"cached_tokens":3}}}"#),
            "data: [DONE]\n\n",
        ]
        let textTurn: [String] = [
            oai(#"{"choices":[{"index":0,"delta":{"role":"assistant","content":"done-oai"},"finish_reason":null}]}"#),
            oai(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
            "data: [DONE]\n\n",
        ]
        let box = ProbeBox()
        let (events, transport) = await runEngine(
            steps: [.events(toolTurn), .events(textTurn)],
            tools: [ProbeTool(box: box, permission: .read)],
            configure: { config in
                config.providerKind = "openai"
                config.baseURL = "https://api.example.com/v1"
                config.model = "gpt-4o"
            })
        expectEqual(box.inputs.count, 1)
        expectEqual(box.inputs.first?["value"]?.intValue, 7)
        guard let (messages, reason) = finished(events) else { return fail("no runFinished") }
        expectEqual(reason, .completed)
        expectEqual(messages.count, 4)
        expect(pairsIntact(messages))
        expectEqual(messages.last?.plainText, "done-oai")

        // Second request must carry the tool result in OpenAI format.
        let second = transport.body(at: 1)
        let sentMessages = second?["messages"]?.arrayValue ?? []
        let toolMessage = sentMessages.first(where: { $0["role"]?.stringValue == "tool" })
        expectEqual(toolMessage?["tool_call_id"]?.stringValue, "call_1")
        expectEqual(toolMessage?["content"]?.stringValue, "probe-ok")

        var sawUsage = false
        for event in events {
            if case .usage(let input, let output, let cacheRead) = event, input > 0 {
                sawUsage = true
                expectEqual(input, 11)
                expectEqual(output, 4)
                expectEqual(cacheRead, 3)
            }
        }
        expect(sawUsage, "expected usage from the OpenAI stream")
    }

    // ---- Compaction

    await test("compaction stage A clears old tool outputs") {
        var messages = [ChatMessage(role: .user, blocks: [.text("start")])]
        for i in 0..<15 {
            messages.append(ChatMessage(role: .assistant, blocks: [
                .toolUse(id: "t\(i)", name: "probe", input: .object([:])),
            ]))
            messages.append(ChatMessage(role: .user, blocks: [
                .toolResult(toolUseId: "t\(i)", content: String(repeating: "x", count: 1200), isError: false),
            ]))
        }
        var config = AgentConfig()
        config.contextTokenBudget = 8_000
        let (compacted, note) = await Compaction.compact(messages, config: config) { _ in "SUMMARY" }
        expect(note != nil)
        let results = toolResults(in: compacted)
        expect(results.contains { $0.content == Compaction.clearedMarker }, "old outputs cleared")
        expect(results.suffix(3).allSatisfy { $0.content != Compaction.clearedMarker },
               "recent outputs kept")
        expect(pairsIntact(compacted))
    }

    await test("compaction stage B summarizes middle without splitting pairs") {
        var messages = [ChatMessage(role: .user, blocks: [.text("the goal")])]
        for _ in 0..<20 {
            messages.append(ChatMessage(role: .assistant,
                                        blocks: [.text(String(repeating: "y", count: 1500))]))
            messages.append(ChatMessage(role: .user,
                                        blocks: [.text(String(repeating: "z", count: 1500))]))
        }
        // Place a tool pair exactly at the keep-recent boundary.
        messages.append(ChatMessage(role: .assistant, blocks: [
            .toolUse(id: "edge", name: "probe", input: .object([:])),
        ]))
        messages.append(ChatMessage(role: .user, blocks: [
            .toolResult(toolUseId: "edge", content: "edge result", isError: false),
        ]))
        for i in 0..<8 {
            messages.append(ChatMessage(role: i % 2 == 0 ? .assistant : .user,
                                        blocks: [.text("recent \(i)")]))
        }
        var config = AgentConfig()
        config.contextTokenBudget = 10_000
        let (compacted, note) = await Compaction.compact(messages, config: config) { _ in "SUMMARY" }
        expect(note?.contains("summarized") == true, "expected stage B, got \(note ?? "nil")")
        expect(compacted.count < messages.count)
        expectEqual(compacted.first?.plainText, "the goal")
        expect(compacted[1].plainText.contains("SUMMARY"))
        expect(pairsIntact(compacted), "boundary must keep the edge tool pair intact")
    }

    await test("compaction: small conversations untouched") {
        let messages = [
            ChatMessage(role: .user, blocks: [.text("hi")]),
            ChatMessage(role: .assistant, blocks: [.text("hello")]),
        ]
        let (compacted, note) = await Compaction.compact(messages, config: AgentConfig()) { _ in "S" }
        expectEqual(compacted.count, 2)
        expect(note == nil)
    }

    // ---- Images (multimodal)

    await test("content block: .image round-trips through Codable") {
        let block = ContentBlock.image(mediaType: "image/png", base64: "aGVsbG8=")
        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
        expectEqual(decoded, block)

        let message = ChatMessage(role: .user, blocks: [.text("look"), block])
        let messageData = try JSONEncoder().encode(message)
        let decodedMessage = try JSONDecoder().decode(ChatMessage.self, from: messageData)
        expectEqual(decodedMessage.blocks, message.blocks)
    }

    await test("request body: anthropic image wire shape") {
        let messages = [
            ChatMessage(role: .user, blocks: [
                .image(mediaType: "image/png", base64: "aGVsbG8="),
                .text("what is this?"),
            ]),
        ]
        let body = RequestBuilder.body(
            messages: messages, systemPrompt: "s", config: AgentConfig(), tools: [],
            thinking: false, runMessageIds: [], cache: false)
        guard let json = try? JSONValue.parse(body) else { return fail("body not JSON") }
        let content = json["messages"]?.arrayValue?.first?["content"]?.arrayValue ?? []
        expectEqual(content.count, 2)
        let imageBlock = content.first { $0["type"]?.stringValue == "image" }
        expectEqual(imageBlock?["source"]?["type"]?.stringValue, "base64")
        expectEqual(imageBlock?["source"]?["media_type"]?.stringValue, "image/png")
        expectEqual(imageBlock?["source"]?["data"]?.stringValue, "aGVsbG8=")
    }

    await test("openai: image block becomes content-array with image_url") {
        let messages = [
            ChatMessage(role: .user, blocks: [
                .text("what is this?"),
                .image(mediaType: "image/jpeg", base64: "aGVsbG8="),
            ]),
        ]
        var config = AgentConfig()
        config.model = "gpt-4o"
        let body = OpenAIRequestBuilder.body(
            messages: messages, systemPrompt: "SYS", config: config, tools: [])
        guard let json = try? JSONValue.parse(body) else { return fail("body not JSON") }
        let sent = json["messages"]?.arrayValue ?? []
        let userMessage = sent.first { $0["role"]?.stringValue == "user" }
        let parts = userMessage?["content"]?.arrayValue ?? []
        expectEqual(parts.count, 2, "text + image parts")
        expectEqual(parts.first?["type"]?.stringValue, "text")
        expectEqual(parts.first?["text"]?.stringValue, "what is this?")
        let imagePart = parts.last
        expectEqual(imagePart?["type"]?.stringValue, "image_url")
        expectEqual(imagePart?["image_url"]?["url"]?.stringValue, "data:image/jpeg;base64,aGVsbG8=")

        // Text-only messages must keep the plain-string content path.
        let textOnly = OpenAIRequestBuilder.body(
            messages: [ChatMessage(role: .user, blocks: [.text("hi")])],
            systemPrompt: "SYS", config: config, tools: [])
        guard let textJSON = try? JSONValue.parse(textOnly) else { return fail("body not JSON") }
        let textUser = textJSON["messages"]?.arrayValue?.first { $0["role"]?.stringValue == "user" }
        expect(textUser?["content"]?.stringValue == "hi", "plain-string path unchanged")
    }
}

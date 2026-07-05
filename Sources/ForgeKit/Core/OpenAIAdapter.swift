import Foundation

// OpenAI-compatible Chat Completions wire format: request building and
// stream collection, mapped onto the same TurnOutcome/AgentEvent surface
// as the Anthropic path so the agent loop stays format-agnostic.

// MARK: - Request

enum OpenAIRequestBuilder {
    static func body(
        messages: [ChatMessage],
        systemPrompt: String,
        config: AgentConfig,
        tools: [any AgentTool],
        maxTokensOverride: Int? = nil
    ) -> Data {
        var wireMessages: [JSONValue] = [
            .object(["role": "system", "content": .string(systemPrompt)]),
        ]
        for message in messages {
            wireMessages.append(contentsOf: encode(message))
        }
        var root: [String: JSONValue] = [
            "model": .string(config.model),
            "stream": .bool(true),
            "stream_options": ["include_usage": true],
            "max_tokens": .number(Double(maxTokensOverride ?? config.maxTokens)),
            "temperature": .number(min(max(config.temperature, 0), 2)),
            "messages": .array(wireMessages),
        ]
        if config.topP < 1.0 {
            root["top_p"] = .number(min(max(config.topP, 0), 1))
        }
        if !tools.isEmpty {
            root["tools"] = .array(tools.map { tool in
                .object([
                    "type": "function",
                    "function": .object([
                        "name": .string(tool.spec.name),
                        "description": .string(tool.spec.description),
                        "parameters": tool.spec.inputSchema,
                    ]),
                ])
            })
        }
        return JSONValue.object(root).encodedData()
    }

    /// One ChatMessage can fan out into several wire messages: tool results
    /// become role:"tool" entries; assistant tool_use becomes tool_calls.
    private static func encode(_ message: ChatMessage) -> [JSONValue] {
        switch message.role {
        case .user:
            var out: [JSONValue] = []
            var texts: [String] = []
            var images: [JSONValue] = []
            for block in message.blocks {
                switch block {
                case .toolResult(let toolUseId, let content, let isError):
                    out.append(.object([
                        "role": "tool",
                        "tool_call_id": .string(toolUseId),
                        "content": .string(isError ? "ERROR: " + content : content),
                    ]))
                case .text(let text) where !text.isEmpty:
                    texts.append(text)
                case .image(let mediaType, let base64):
                    images.append(.object([
                        "type": "image_url",
                        "image_url": .object([
                            "url": .string("data:\(mediaType);base64,\(base64)"),
                        ]),
                    ]))
                default:
                    break
                }
            }
            if !images.isEmpty {
                var parts: [JSONValue] = []
                if !texts.isEmpty {
                    parts.append(.object(["type": "text", "text": .string(texts.joined(separator: "\n"))]))
                }
                parts.append(contentsOf: images)
                out.append(.object([
                    "role": "user",
                    "content": .array(parts),
                ]))
            } else if !texts.isEmpty {
                out.append(.object([
                    "role": "user",
                    "content": .string(texts.joined(separator: "\n")),
                ]))
            }
            return out

        case .assistant:
            var texts: [String] = []
            var toolCalls: [JSONValue] = []
            for block in message.blocks {
                switch block {
                case .text(let text) where !text.isEmpty:
                    texts.append(text)
                case .toolUse(let id, let name, let input):
                    toolCalls.append(.object([
                        "id": .string(id),
                        "type": "function",
                        "function": .object([
                            "name": .string(name),
                            "arguments": .string(input.encodedString()),
                        ]),
                    ]))
                default:
                    break   // thinking is never replayed to OpenAI backends
                }
            }
            var object: [String: JSONValue] = ["role": "assistant"]
            if !texts.isEmpty { object["content"] = .string(texts.joined(separator: "\n")) }
            if !toolCalls.isEmpty { object["tool_calls"] = .array(toolCalls) }
            guard object.count > 1 else { return [] }
            return [.object(object)]
        }
    }
}

// MARK: - Stream

/// Collects Chat Completions chunks (`data: {...}` / `data: [DONE]`).
final class OpenAIStreamCollector: StreamCollecting {
    private let messageId = UUID()
    private let yield: (AgentEvent) -> Void
    private let toolsByName: [String: any AgentTool]

    private struct PartialCall {
        var id: String
        var name: String
        var arguments: String
    }

    private var text = ""
    private var reasoning = ""
    private var calls: [Int: PartialCall] = [:]
    private var callOrder: [Int] = []
    private var finishReason: String?
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
        guard event.data != "[DONE]" else { return }
        guard let json = try? JSONValue.parse(event.data) else { return }

        if let error = json["error"] {
            throw APIError.streamError(
                type: error["type"]?.stringValue ?? "api_error",
                message: error["message"]?.stringValue ?? event.data)
        }

        if !started {
            started = true
            yield(.messageStarted(id: messageId, role: .assistant))
        }

        if let usage = json["usage"], usage != .null {
            inputTokens = usage["prompt_tokens"]?.intValue ?? inputTokens
            outputTokens = usage["completion_tokens"]?.intValue ?? outputTokens
            cacheReadTokens = usage["prompt_tokens_details"]?["cached_tokens"]?.intValue
                ?? cacheReadTokens
        }

        guard let choice = json["choices"]?.arrayValue?.first else { return }
        if let reason = choice["finish_reason"]?.stringValue {
            finishReason = reason
        }
        guard let delta = choice["delta"] else { return }

        if let piece = delta["content"]?.stringValue, !piece.isEmpty {
            text += piece
            yield(.textDelta(messageId: messageId, delta: piece))
        }
        if let piece = delta["reasoning_content"]?.stringValue, !piece.isEmpty {
            reasoning += piece
            yield(.thinkingDelta(messageId: messageId, delta: piece))
        }
        if let toolDeltas = delta["tool_calls"]?.arrayValue {
            for toolDelta in toolDeltas {
                let index = toolDelta["index"]?.intValue ?? 0
                if calls[index] == nil {
                    let id = toolDelta["id"]?.stringValue ?? "call_\(UUID().uuidString.prefix(8))"
                    let name = toolDelta["function"]?["name"]?.stringValue ?? "unknown"
                    calls[index] = PartialCall(id: id, name: name, arguments: "")
                    callOrder.append(index)
                    yield(.toolCallStarted(messageId: messageId, toolUseId: id, name: name))
                }
                if let name = toolDelta["function"]?["name"]?.stringValue,
                   calls[index]?.name == "unknown" {
                    calls[index]?.name = name
                }
                if let fragment = toolDelta["function"]?["arguments"]?.stringValue {
                    calls[index]?.arguments += fragment
                }
            }
        }
    }

    func finishTurn() throws -> TurnOutcome {
        guard started else {
            throw APIError.badResponse("stream ended before any chunk arrived")
        }
        yield(.usage(inputTokens: inputTokens, outputTokens: outputTokens,
                     cacheReadTokens: cacheReadTokens))

        var blocks: [ContentBlock] = []
        if !reasoning.isEmpty {
            // Unsigned: shown in the UI, never replayed to the API.
            blocks.append(.thinking(reasoning, signature: nil))
        }
        if !text.isEmpty {
            blocks.append(.text(text))
        }
        for index in callOrder {
            guard let call = calls[index] else { continue }
            let input = (try? JSONValue.parse(
                call.arguments.isEmpty ? "{}" : call.arguments)) ?? .object([:])
            let summary = toolsByName[call.name]?.summarize(input: input) ?? call.name
            yield(.toolCallReady(messageId: messageId, toolUseId: call.id, name: call.name,
                                 input: input, summary: summary))
            blocks.append(.toolUse(id: call.id, name: call.name, input: input))
        }

        let stopReason: String
        switch finishReason {
        case "tool_calls": stopReason = "tool_use"
        case "length": stopReason = "max_tokens"
        default: stopReason = "end_turn"
        }
        return TurnOutcome(
            message: ChatMessage(id: messageId, role: .assistant, blocks: blocks),
            stopReason: stopReason)
    }
}

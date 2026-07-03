import Foundation

// MARK: - Errors

enum APIError: Error, CustomStringConvertible {
    case http(status: Int, message: String)
    case network(String)
    /// An SSE `error` event arrived mid-stream.
    case streamError(type: String, message: String)
    case badResponse(String)

    var isRetryable: Bool {
        switch self {
        case .http(let status, _): return status == 429 || status >= 500
        case .network: return true
        case .streamError(let type, _): return type == "overloaded_error" || type == "api_error"
        case .badResponse: return false
        }
    }

    var shortLabel: String {
        switch self {
        case .http(let status, _): return "HTTP \(status)"
        case .network: return "network error"
        case .streamError(let type, _): return type
        case .badResponse: return "bad response"
        }
    }

    var description: String {
        switch self {
        case .http(let status, let message): return "API error \(status): \(message)"
        case .network(let message): return "Network error: \(message)"
        case .streamError(let type, let message): return "API stream error (\(type)): \(message)"
        case .badResponse(let message): return "Unexpected API response: \(message)"
        }
    }
}

// MARK: - Transport

/// A fully-formed POST: URL, headers and JSON body. Built per provider
/// format by the engine; the transport just moves bytes.
struct WireRequest: Sendable {
    var url: URL
    var headers: [String: String]
    var body: Data

    /// Anthropic Messages API request.
    static func anthropic(baseURL: String, apiKey: String, body: Data) -> WireRequest {
        WireRequest(
            url: URL(string: baseURL + "/v1/messages")
                ?? URL(string: "https://api.anthropic.com/v1/messages")!,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
                "accept": "text/event-stream",
            ],
            body: body)
    }

    /// OpenAI-compatible Chat Completions request. `baseURL` includes the
    /// version prefix by convention (e.g. https://api.openai.com/v1).
    static func openAI(baseURL: String, apiKey: String, body: Data) -> WireRequest {
        WireRequest(
            url: URL(string: baseURL + "/chat/completions")
                ?? URL(string: "https://api.openai.com/v1/chat/completions")!,
            headers: [
                "Authorization": "Bearer " + apiKey,
                "content-type": "application/json",
                "accept": "text/event-stream",
            ],
            body: body)
    }
}

/// Abstracts the HTTP layer so the agent loop is testable offline.
protocol APITransport: Sendable {
    /// POSTs the request and returns the raw SSE byte stream.
    func send(_ request: WireRequest) async throws -> AsyncThrowingStream<Data, Error>
}

struct URLSessionTransport: APITransport {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    func send(_ wire: WireRequest) async throws -> AsyncThrowingStream<Data, Error> {
        var request = URLRequest(url: wire.url)
        request.httpMethod = "POST"
        request.httpBody = wire.body
        for (field, value) in wire.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await Self.session.bytes(for: request)
        } catch let error as URLError {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badResponse("not an HTTP response")
        }
        if http.statusCode != 200 {
            var data = Data()
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 64_000 { break }
                }
            } catch { /* keep whatever body we got */ }
            throw APIError.http(
                status: http.statusCode,
                message: Self.errorMessage(from: data) ?? String(decoding: data, as: UTF8.self)
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    for try await byte in bytes {
                        chunk.append(byte)
                        // Yield per line — low latency without per-byte overhead.
                        if byte == 0x0A || chunk.count >= 4096 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: APIError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let value = try? JSONValue.parse(data) else { return nil }
        return value["error"]?["message"]?.stringValue
    }
}

// MARK: - Request building

enum RequestBuilder {
    /// Assembles a Messages API request body. Order tools → system →
    /// messages with cache breakpoints on the system block and the last
    /// message's last block (when `cache` is on). `runMessageIds` marks the
    /// assistant messages created during the current run — only their
    /// thinking blocks are replayed; historical thinking is stripped.
    static func body(
        messages: [ChatMessage],
        systemPrompt: String,
        config: AgentConfig,
        tools: [any AgentTool],
        thinking: Bool,
        runMessageIds: Set<UUID>,
        maxTokensOverride: Int? = nil,
        modelOverride: String? = nil,
        stream: Bool = true,
        cache: Bool = true
    ) -> Data {
        var root: [String: JSONValue] = [
            "model": .string(modelOverride ?? config.model),
            "max_tokens": .number(Double(maxTokensOverride ?? config.maxTokens)),
            "stream": .bool(stream),
        ]
        // Anthropic discourages combining temperature and top_p; send one.
        if config.topP < 1.0 {
            root["top_p"] = .number(min(max(config.topP, 0), 1))
        } else {
            root["temperature"] = .number(min(max(config.temperature, 0), 1))
        }
        if !tools.isEmpty {
            root["tools"] = .array(tools.map { tool in
                .object([
                    "name": .string(tool.spec.name),
                    "description": .string(tool.spec.description),
                    "input_schema": tool.spec.inputSchema,
                ])
            })
        }
        var systemBlock: [String: JSONValue] = [
            "type": "text",
            "text": .string(systemPrompt),
        ]
        if cache { systemBlock["cache_control"] = ["type": "ephemeral"] }
        root["system"] = .array([.object(systemBlock)])
        if thinking {
            root["thinking"] = ["type": "adaptive"]
        }

        var encoded: [JSONValue] = []
        for message in messages {
            let blocks = encodeBlocks(
                message.blocks,
                stripThinking: !runMessageIds.contains(message.id)
            )
            guard !blocks.isEmpty else { continue }
            encoded.append(.object([
                "role": .string(message.role.rawValue),
                "content": .array(blocks),
            ]))
        }
        encoded = mergeConsecutiveRoles(encoded)
        if cache, let last = encoded.indices.last {
            encoded[last] = addCacheControlToLastBlock(encoded[last])
        }
        root["messages"] = .array(encoded)
        return JSONValue.object(root).encodedData()
    }

    /// Compaction can leave two user messages adjacent (summary + tail);
    /// merge them so the request never carries consecutive same-role turns.
    private static func mergeConsecutiveRoles(_ messages: [JSONValue]) -> [JSONValue] {
        var merged: [JSONValue] = []
        for message in messages {
            if let last = merged.last,
               last["role"] == message["role"],
               var lastObject = last.objectValue,
               let lastContent = lastObject["content"]?.arrayValue,
               let nextContent = message["content"]?.arrayValue {
                lastObject["content"] = .array(lastContent + nextContent)
                merged[merged.count - 1] = .object(lastObject)
            } else {
                merged.append(message)
            }
        }
        return merged
    }

    private static func encodeBlocks(_ blocks: [ContentBlock], stripThinking: Bool) -> [JSONValue] {
        blocks.compactMap { block in
            switch block {
            case .text(let text):
                guard !text.isEmpty else { return nil }
                return .object(["type": "text", "text": .string(text)])
            case .thinking(let text, let signature):
                // Thinking is replayed byte-identical within the current run
                // only; unsigned or historical thinking is dropped.
                guard !stripThinking, let signature, !signature.isEmpty else { return nil }
                return .object([
                    "type": "thinking",
                    "thinking": .string(text),
                    "signature": .string(signature),
                ])
            case .toolUse(let id, let name, let input):
                return .object([
                    "type": "tool_use",
                    "id": .string(id),
                    "name": .string(name),
                    "input": input,
                ])
            case .toolResult(let toolUseId, let content, let isError):
                var object: [String: JSONValue] = [
                    "type": "tool_result",
                    "tool_use_id": .string(toolUseId),
                    "content": .string(content),
                ]
                if isError { object["is_error"] = .bool(true) }
                return .object(object)
            }
        }
    }

    private static func addCacheControlToLastBlock(_ message: JSONValue) -> JSONValue {
        guard var object = message.objectValue,
              var content = object["content"]?.arrayValue,
              let lastIndex = content.indices.last,
              var block = content[lastIndex].objectValue else { return message }
        // cache_control is invalid on thinking blocks; skip in that case.
        if block["type"]?.stringValue == "thinking" { return message }
        block["cache_control"] = ["type": "ephemeral"]
        content[lastIndex] = .object(block)
        object["content"] = .array(content)
        return .object(object)
    }
}

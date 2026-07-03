import Foundation
@testable import ForgeKit

// End-to-end: user message → AppState → engine (mock transport) → real
// write_file tool → auto-approval → transcript folding → session persisted.

private func sse(_ name: String, _ json: String) -> String {
    "event: \(name)\ndata: \(json)\n\n"
}

private func e2eToolTurn() -> [String] {
    let fragment = #"{\"path\": \"hello.txt\", \"content\": \"hi from forge\"}"#
    return [
        sse("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":20,"cache_read_input_tokens":0}}}"#),
        sse("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_e2e","name":"write_file","input":{}}}"#),
        sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\#(fragment)"}}"#),
        sse("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        sse("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":15}}"#),
        sse("message_stop", #"{"type":"message_stop"}"#),
    ]
}

private func e2eTextTurn() -> [String] {
    [
        sse("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":30,"cache_read_input_tokens":10}}}"#),
        sse("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
        sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Created hello.txt"}}"#),
        sse("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        sse("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":6}}"#),
        sse("message_stop", #"{"type":"message_stop"}"#),
    ]
}

private final class TestKeychain: KeychainProtocol, @unchecked Sendable {
    private let lock = NSLock()
    // sk-ant- prefix → the migration wraps it into an Anthropic provider.
    private var key: String? = "sk-ant-test"
    private var providersData: Data?

    func getApiKey() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return key
    }

    func setApiKey(_ newKey: String) throws {
        lock.lock(); defer { lock.unlock() }
        key = newKey
    }

    func deleteApiKey() throws {
        lock.lock(); defer { lock.unlock() }
        key = nil
    }

    func getProvidersData() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return providersData
    }

    func setProvidersData(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        providersData = data.isEmpty ? nil : data
    }
}

func e2eTests() async {

    await test("end-to-end: chat → tool call → approval → result → persisted") {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-e2e-ws-" + UUID().uuidString, isDirectory: true)
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-e2e-store-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: storeDir)
        }

        let transport = MockTransport([
            .events(e2eToolTurn()),
            .events(e2eTextTurn()),
        ])

        let state = await MainActor.run { () -> AppState in
            let state = AppState(
                engine: AgentEngine(transport: transport),
                tools: makeDefaultTools(),
                store: FileSessionStore(baseDir: storeDir),
                keychain: TestKeychain())
            state.settings.workspaceRoot = workspace.path
            state.settings.autoApprove = true   // resolves approval instantly
            state.newSession()
            return state
        }

        await MainActor.run { state.send("create hello.txt") }

        var running = true
        for _ in 0..<100 where running {
            try? await Task.sleep(nanoseconds: 50_000_000)
            running = await MainActor.run { state.isRunning }
        }
        expect(!running, "run must complete within 5s")

        let written = try? String(
            contentsOf: workspace.appendingPathComponent("hello.txt"), encoding: .utf8)
        expectEqual(written, "hi from forge")

        let (messages, hints, tokens) = await MainActor.run {
            (state.messages, state.displayHints, state.totalInputTokens)
        }
        expectEqual(messages.count, 4,
                    "user, assistant(tool_use), user(tool_result), assistant(text)")
        expect(pairsIntact(messages))
        expectEqual(messages.last?.plainText, "Created hello.txt")
        if case .diff(let path, _, let new)? = hints["tu_e2e"] {
            expectEqual(path, "hello.txt")
            expectEqual(new, "hi from forge")
        } else {
            fail("expected a diff display hint for the write")
        }
        expectEqual(tokens, 50, "20 + 30 input tokens across two calls")

        let persisted = (try? FileSessionStore(baseDir: storeDir).listSessions()) ?? []
        expectEqual(persisted.count, 1)
        expectEqual(persisted.first?.messages.count, 4)
        expect(persisted.first?.title.contains("create hello.txt") == true)
    }
}

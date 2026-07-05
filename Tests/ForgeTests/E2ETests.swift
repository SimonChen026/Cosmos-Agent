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

private func e2eTextTurn(text: String = "Created hello.txt") -> [String] {
    [
        sse("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":30,"cache_read_input_tokens":10}}}"#),
        sse("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
        sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}"#),
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
            .events(e2eTextTurn(text: "Create Hello File")),   // smart-title call
        ])

        let state = await MainActor.run { () -> AppState in
            let state = AppState(
                engine: AgentEngine(transport: transport),
                tools: makeDefaultTools(),
                store: FileSessionStore(baseDir: storeDir),
                keychain: TestKeychain())
            state.settings.workspaceRoot = workspace.path
            state.settings.permissionLevel = .bypassAll   // resolves approval instantly
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

        // The crude fallback (first 48 chars) is replaced by an async
        // smart-title call once the first reply completes — wait for it.
        var title = persisted.first?.title
        for _ in 0..<100 where title != "Create Hello File" {
            try? await Task.sleep(nanoseconds: 50_000_000)
            title = (try? FileSessionStore(baseDir: storeDir).listSessions())?.first?.title
        }
        expectEqual(title, "Create Hello File")
    }

    await test("providers: one key → many models, grouped by account") {
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-prov-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }

        let state = await MainActor.run { () -> AppState in
            let s = AppState(
                engine: AgentEngine(transport: MockTransport([])),
                tools: makeDefaultTools(),
                store: FileSessionStore(baseDir: storeDir),
                keychain: TestKeychain())
            s.providers = []   // start clean (ignore migrated dev key)
            return s
        }

        // One Anthropic key expands to every catalog model, one account.
        await MainActor.run { state.addKeys("sk-ant-abc123") }
        let afterAnthropic = await MainActor.run {
            (state.providers.count, state.accounts.count,
             state.providers.allSatisfy { $0.apiKey == "sk-ant-abc123" })
        }
        expectEqual(afterAnthropic.0, ModelCatalog.models.count, "all Claude models added")
        expectEqual(afterAnthropic.1, 1, "one account for the key")
        expect(afterAnthropic.2, "every model shares the one key")

        // Tiers were auto-assigned (haiku → fast, opus/fable → strong).
        let tiers = await MainActor.run {
            Dictionary(uniqueKeysWithValues: state.providers.map { ($0.model, $0.tier) })
        }
        expect(tiers["claude-haiku-4-5-20251001"] == "fast")
        expect(tiers["claude-opus-4-8"] == "strong")

        // A DeepSeek key adds a second account with one model.
        await MainActor.run {
            state.addKeys("sk-deepseek-xyz", baseURL: "https://api.deepseek.com", model: nil)
        }
        let twoAccounts = await MainActor.run { state.accounts.count }
        expectEqual(twoAccounts, 2, "second credential → second account")
        let deepseekModel = await MainActor.run {
            state.accounts.first(where: { $0.kind == "openai" })?.models.first?.model
        }
        expectEqual(deepseekModel, "deepseek-chat", "endpoint-inferred default model")

        // Add another model under the DeepSeek account.
        await MainActor.run {
            if let acct = state.accounts.first(where: { $0.kind == "openai" }) {
                state.addModel(to: acct, model: "deepseek-reasoner")
            }
        }
        let deepseekModels = await MainActor.run {
            state.accounts.first(where: { $0.kind == "openai" })?.models.count ?? 0
        }
        expectEqual(deepseekModels, 2, "second model added under same key")

        // Removing the account drops all its models.
        await MainActor.run {
            if let acct = state.accounts.first(where: { $0.kind == "openai" }) {
                state.deleteAccount(acct)
            }
        }
        let remaining = await MainActor.run { state.accounts.count }
        expectEqual(remaining, 1, "deleting an account removes all its models")
    }

    await test("sessions: rename survives auto-title on later saves") {
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-rename-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }

        let state = await MainActor.run { () -> AppState in
            AppState(
                engine: AgentEngine(transport: MockTransport([])),
                tools: makeDefaultTools(),
                store: FileSessionStore(baseDir: storeDir),
                keychain: TestKeychain())
        }

        let id = await MainActor.run { () -> UUID in
            state.newSession()
            state.messages = [ChatMessage(role: .user, blocks: [.text("first message")])]
            state.persistCurrentSession()
            return state.currentSessionId!
        }
        let autoTitle = await MainActor.run { state.sessions.first(where: { $0.id == id })?.title }
        expectEqual(autoTitle, "first message", "auto-derived from first user message")

        await MainActor.run { state.renameSession(id, to: "My Custom Name") }
        let renamed = await MainActor.run { state.sessions.first(where: { $0.id == id })?.title }
        expectEqual(renamed, "My Custom Name")

        // A later save (more messages) must NOT clobber the custom title.
        await MainActor.run {
            state.selectSession(id)
            state.messages.append(ChatMessage(role: .assistant, blocks: [.text("reply")]))
            state.persistCurrentSession()
        }
        let stillRenamed = await MainActor.run { state.sessions.first(where: { $0.id == id })?.title }
        expectEqual(stillRenamed, "My Custom Name", "custom title survives later auto-saves")
    }

    await test("presentApproval: permission tiers gate write/execute correctly") {
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-perm-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }

        let state = await MainActor.run { () -> AppState in
            AppState(
                engine: AgentEngine(transport: MockTransport([])),
                tools: makeDefaultTools(),
                store: FileSessionStore(baseDir: storeDir),
                keychain: TestKeychain())
        }

        func decide(_ level: PermissionLevel, toolName: String, command: String? = nil) async -> ApprovalDecision {
            await MainActor.run {
                state.settings.permissionLevel = level
                state.settings.alwaysAllowed = []
            }
            let input: JSONValue = command.map { .object(["command": .string($0)]) } ?? .object([:])
            return await withCheckedContinuation { cont in
                Task { @MainActor in
                    state.presentApproval(toolName: toolName, summary: "test", input: input) { decision in
                        cont.resume(returning: decision)
                    }
                    // Any decision not resolved synchronously means a dialog
                    // was presented — treat that as "asked" rather than hang.
                    if state.pendingApproval != nil {
                        state.pendingApproval = nil
                        cont.resume(returning: .deny)
                    }
                }
            }
        }

        let readOnlyDenies = await decide(.readOnly, toolName: "write_file")
        expectEqual(readOnlyDenies, .deny, "readOnly denies a write tool with no UI")
        let readOnlyStillNoUI = await MainActor.run { state.pendingApproval == nil }
        expect(readOnlyStillNoUI, "readOnly must not show approval UI for write tools")

        let acceptEditsWrite = await decide(.acceptEdits, toolName: "write_file")
        expectEqual(acceptEditsWrite, .allowOnce, "acceptEdits auto-allows write")

        let acceptEditsBash = await decide(.acceptEdits, toolName: "bash", command: "npm test")
        expectEqual(acceptEditsBash, .deny, "acceptEdits still asks for execute (simulated as deny since no UI response)")

        let acceptAllWrite = await decide(.acceptAll, toolName: "write_file")
        expectEqual(acceptAllWrite, .allowOnce, "acceptAll auto-allows write")

        let acceptAllBash = await decide(.acceptAll, toolName: "bash", command: "npm test")
        expectEqual(acceptAllBash, .allowOnce, "acceptAll auto-allows a non-dangerous command")

        let acceptAllDangerous = await decide(.acceptAll, toolName: "bash", command: "sudo rm -rf /tmp/x")
        expectEqual(acceptAllDangerous, .deny, "acceptAll still asks for a dangerous command (simulated as deny since no UI response)")

        let bypassAllDangerous = await decide(.bypassAll, toolName: "bash", command: "sudo rm -rf /tmp/x")
        expectEqual(bypassAllDangerous, .allowOnce, "bypassAll auto-allows even a dangerous command")
    }

    await test("artifact: a create_artifact tool result upserts state.artifacts and selects it") {
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-artifact-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }

        let state = await MainActor.run { () -> AppState in
            AppState(
                engine: AgentEngine(transport: MockTransport([])),
                tools: makeDefaultTools(),
                store: FileSessionStore(baseDir: storeDir),
                keychain: TestKeychain())
        }

        let messageId = UUID()
        await MainActor.run {
            state.newSession()
            state.handleForTest(.messageStarted(id: messageId, role: .assistant))
            state.handleForTest(.toolResult(
                toolUseId: "tu_artifact_1",
                name: "create_artifact",
                output: ToolOutput(
                    content: "Created artifact: Demo",
                    displayHint: .artifact(id: "art-1", title: "Demo", kind: "code",
                                           language: "swift", content: "print(1)")
                )
            ))
        }

        let (artifacts, selected) = await MainActor.run { (state.artifacts, state.selectedArtifactId) }
        expectEqual(artifacts.count, 1)
        expectEqual(artifacts.first?.id, "art-1")
        expectEqual(artifacts.first?.title, "Demo")
        expectEqual(selected, "art-1")

        // A second result with the same id updates in place rather than appending.
        await MainActor.run {
            state.handleForTest(.toolResult(
                toolUseId: "tu_artifact_2",
                name: "create_artifact",
                output: ToolOutput(
                    content: "Updated artifact: Demo v2",
                    displayHint: .artifact(id: "art-1", title: "Demo v2", kind: "code",
                                           language: "swift", content: "print(2)")
                )
            ))
        }
        let updated = await MainActor.run { state.artifacts }
        expectEqual(updated.count, 1, "same id must update in place, not append")
        expectEqual(updated.first?.title, "Demo v2")

        // Switching sessions must not leak artifacts into the new one.
        await MainActor.run { state.newSession() }
        let (afterNewSession, afterSelected) = await MainActor.run { (state.artifacts, state.selectedArtifactId) }
        expect(afterNewSession.isEmpty, "artifacts must not leak across sessions")
        expect(afterSelected == nil)
    }

    await test("sessions: smart title replaces the first-48-chars fallback after the first reply") {
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-smarttitle-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }

        func textTurn(_ text: String) -> [String] {
            [
                sse("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":0}}}"#),
                sse("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
                sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}"#),
                sse("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
                sse("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#),
                sse("message_stop", #"{"type":"message_stop"}"#),
            ]
        }

        let transport = MockTransport([
            .events(textTurn("Sure — Swift concurrency uses async/await and actors.")),
            .events(textTurn("Swift Concurrency Basics")),
        ])

        let state = await MainActor.run { () -> AppState in
            let s = AppState(
                engine: AgentEngine(transport: transport),
                tools: makeDefaultTools(),
                store: FileSessionStore(baseDir: storeDir),
                keychain: TestKeychain())
            s.providers = [Provider(name: "j", kind: "anthropic", baseURL: "https://api.anthropic.com",
                                    model: "claude-haiku-4-5-20251001", apiKey: "sk-ant-test", tier: "fast")]
            s.settings.permissionLevel = .bypassAll
            s.newSession()
            return s
        }

        await MainActor.run { state.send("Tell me about Swift concurrency") }

        var running = true
        for _ in 0..<100 where running {
            try? await Task.sleep(nanoseconds: 50_000_000)
            running = await MainActor.run { state.isRunning }
        }
        expect(!running, "main run must complete within 5s")

        // The async smart-title call resolves quickly (a mock, no real
        // network) — poll rather than assume the crude fallback is still
        // observable, since it can already be replaced by the time we look.
        var finalTitle = await MainActor.run { state.sessions.first?.title }
        for _ in 0..<100 where finalTitle != "Swift Concurrency Basics" {
            try? await Task.sleep(nanoseconds: 50_000_000)
            finalTitle = await MainActor.run { state.sessions.first?.title }
        }
        expectEqual(finalTitle, "Swift Concurrency Basics")

        // It's sticky — persisted as customTitle, so a later persist call
        // (e.g. from a second message) must not revert to the fallback.
        let persisted = (try? FileSessionStore(baseDir: storeDir).listSessions())?.first
        expectEqual(persisted?.customTitle, "Swift Concurrency Basics")
    }
}

import Foundation
import SwiftUI

// =====================================================================
// AppState — the integration hub. Owned by the scaffold (do not rewrite;
// builders may only read this file to learn the surface they target).
// =====================================================================

struct AppSettings: Codable, Equatable {
    var model: String = ModelCatalog.defaultModel
    var maxTurns: Int = 50
    var autoApprove: Bool = false
    var workspaceRoot: String = NSHomeDirectory()
    var thinkingMode: String = "adaptive"
    /// Persisted "always allow" keys: a tool name ("edit_file") or a
    /// bash first-token rule ("bash:npm").
    var alwaysAllowed: [String] = []
    /// UUID string of the provider the main agent uses (subagents rotate
    /// across all providers). Nil → first provider.
    var primaryProviderId: String?
    /// Regex difficulty routing: classify each user message and pick a
    /// provider of the matching tier automatically.
    var autoRoute: Bool = true
    var routingRules: [RoutingRule] = RoutingRule.defaults
}

@MainActor
final class AppState: ObservableObject {

    // MARK: Published state (the UI renders exactly this)

    @Published var sessions: [SessionRecord] = []
    @Published var currentSessionId: UUID?
    @Published var messages: [ChatMessage] = []
    @Published var isRunning = false
    @Published var pendingApproval: PendingApproval?
    @Published var settings: AppSettings {
        didSet { persistSettings() }
    }
    @Published var lastError: String?
    @Published var totalInputTokens = 0
    @Published var totalOutputTokens = 0
    @Published var cacheReadTokens = 0
    @Published var statusText: String?
    @Published var apiKeyPresent = false
    @Published var providers: [Provider] = []
    @Published var currentTodos: [TodoItem] = []
    /// Rich render payloads keyed by toolUseId (diffs etc.) — display-only,
    /// not persisted with the transcript.
    @Published var displayHints: [String: DisplayHint] = [:]
    /// Set by empty-state prompt chips; the input bar consumes it.
    @Published var composerSeed: String?

    struct PendingApproval: Identifiable {
        let id = UUID()
        let toolName: String
        let summary: String
        let input: JSONValue
        let respond: (ApprovalDecision) -> Void
    }

    // MARK: Dependencies

    let engine: any AgentEngineProtocol
    let tools: [any AgentTool]
    let store: any SessionStoreProtocol
    let keychain: any KeychainProtocol

    private var runTask: Task<Void, Never>?
    private var toolSession = ToolSessionState()
    /// Bumped on every startRun; events from superseded runs are dropped.
    private var runGeneration = 0

    var workspaceURL: URL {
        URL(fileURLWithPath: (settings.workspaceRoot as NSString).expandingTildeInPath)
    }

    // MARK: Init

    init(engine: any AgentEngineProtocol,
         tools: [any AgentTool],
         store: any SessionStoreProtocol,
         keychain: any KeychainProtocol) {
        self.engine = engine
        self.tools = tools
        self.store = store
        self.keychain = keychain
        self.settings = Self.loadSettings()
        settings.model = ModelCatalog.defaultModel
        loadProviders()
        refreshApiKeyPresence()
        refreshSessions()
        if let latest = sessions.first {
            selectSession(latest.id)
        } else {
            newSession()
        }
    }

    // MARK: Sending / running

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        guard apiKeyPresent else {
            lastError = "No API key configured. Open Settings (⌘,) and paste your Anthropic API key."
            return
        }
        lastError = nil
        messages.append(ChatMessage(role: .user, blocks: [.text(trimmed)]))
        persistCurrentSession()
        startRun()
    }

    func stopRun() {
        engine.cancel()
        if let pa = pendingApproval {
            pa.respond(.deny)
            pendingApproval = nil
        }
    }

    private func startRun() {
        guard var provider = activeProvider else {
            lastError = "No API key configured. Paste one on the start screen or in Settings (⌘,)."
            return
        }
        // Difficulty routing: regex-classify the newest user message and
        // pick a provider of the matching tier.
        if settings.autoRoute, providers.count > 1,
           let lastUser = messages.last(where: { $0.role == .user })?.plainText {
            let tier = DifficultyRouter.tier(for: lastUser, rules: settings.routingRules)
            if let routed = DifficultyRouter.candidates(tier: tier, from: providers).first {
                provider = routed
                statusText = "difficulty: \(tier) → \(routed.name) · \(routed.model)"
            }
        }
        var config = AgentConfig()
        config.apiKey = provider.apiKey
        config.model = provider.model
        config.providerKind = provider.kind
        config.baseURL = provider.baseURL
        config.temperature = provider.temperature
        config.topP = provider.topP
        config.maxTokens = provider.maxTokens
        config.maxTurns = settings.maxTurns
        config.workspaceRoot = workspaceURL.path
        config.autoApprove = settings.autoApprove
        config.thinkingMode = settings.thinkingMode

        let request = AgentRunRequest(
            messages: messages,
            systemPrompt: buildSystemPrompt(workspaceRoot: workspaceURL.path, model: provider.model),
            config: config,
            tools: tools,
            session: toolSession,
            providers: providers
        )
        isRunning = true
        statusText = "thinking…"
        runGeneration += 1
        let generation = runGeneration
        let sessionAtStart = currentSessionId
        let broker = AppApprovalBroker(state: self)
        let engine = self.engine
        runTask = Task { [weak self] in
            for await event in engine.run(request, approval: broker) {
                guard let self, self.runGeneration == generation,
                      self.currentSessionId == sessionAtStart else { continue }
                self.handle(event)
            }
            guard let self, self.runGeneration == generation else { return }
            self.isRunning = false
            self.statusText = nil
            if self.currentSessionId == sessionAtStart {
                self.persistCurrentSession()
            }
        }
    }

    // MARK: Event folding

    private func handle(_ event: AgentEvent) {
        switch event {
        case .messageStarted(let id, let role):
            messages.append(ChatMessage(id: id, role: role, blocks: []))

        case .textDelta(let messageId, let delta):
            appendText(delta, to: messageId)

        case .thinkingDelta(let messageId, let delta):
            appendThinking(delta, to: messageId)

        case .toolCallStarted(let messageId, let toolUseId, let name):
            guard let i = index(of: messageId) else { break }
            messages[i].blocks.append(.toolUse(id: toolUseId, name: name, input: .object([:])))
            statusText = name

        case .toolCallReady(let messageId, let toolUseId, let name, let input, let summary):
            guard let i = index(of: messageId) else { break }
            if let b = messages[i].blocks.firstIndex(where: { blockToolUseId($0) == toolUseId }) {
                messages[i].blocks[b] = .toolUse(id: toolUseId, name: name, input: input)
            }
            statusText = summary

        case .toolResult(let toolUseId, _, let output):
            if case .todoList(let items)? = output.displayHint {
                currentTodos = items
            }
            if let hint = output.displayHint {
                displayHints[toolUseId] = hint
            }
            let block = ContentBlock.toolResult(
                toolUseId: toolUseId,
                content: output.content,
                isError: output.isError
            )
            if let last = messages.indices.last, messages[last].role == .user,
               messages[last].blocks.allSatisfy(isToolResultBlock) {
                messages[last].blocks.append(block)
            } else {
                messages.append(ChatMessage(role: .user, blocks: [block]))
            }

        case .usage(let input, let output, let cacheRead):
            totalInputTokens += input
            totalOutputTokens += output
            cacheReadTokens += cacheRead

        case .info(let text):
            statusText = text

        case .runFinished(let final, let reason):
            messages = final
            switch reason {
            case .failed(let message): lastError = message
            case .maxTurnsReached: lastError = "Stopped: reached the maximum number of turns."
            case .cancelled, .completed: break
            }
        }
    }

    private func index(of messageId: UUID) -> Int? {
        messages.lastIndex(where: { $0.id == messageId })
    }

    private func blockToolUseId(_ block: ContentBlock) -> String? {
        if case .toolUse(let id, _, _) = block { return id }
        return nil
    }

    private func isToolResultBlock(_ block: ContentBlock) -> Bool {
        if case .toolResult = block { return true }
        return false
    }

    private func appendText(_ delta: String, to messageId: UUID) {
        guard let i = index(of: messageId) else { return }
        if case .text(let t)? = messages[i].blocks.last {
            messages[i].blocks[messages[i].blocks.count - 1] = .text(t + delta)
        } else {
            messages[i].blocks.append(.text(delta))
        }
        statusText = nil
    }

    private func appendThinking(_ delta: String, to messageId: UUID) {
        guard let i = index(of: messageId) else { return }
        if case .thinking(let t, let sig)? = messages[i].blocks.last {
            messages[i].blocks[messages[i].blocks.count - 1] = .thinking(t + delta, signature: sig)
        } else {
            messages[i].blocks.append(.thinking(delta, signature: nil))
        }
        statusText = "thinking…"
    }

    // MARK: Approval

    func presentApproval(toolName: String, summary: String, input: JSONValue,
                         respond: @escaping (ApprovalDecision) -> Void) {
        let key = Self.allowKey(toolName: toolName, input: input)
        let command = (toolName == "bash") ? (input["command"]?.stringValue ?? "") : ""

        let dangerous = !command.isEmpty && BashSafety.isDangerous(command)
        if !dangerous {
            if settings.autoApprove
                || settings.alwaysAllowed.contains(key)
                || settings.alwaysAllowed.contains(toolName) {
                respond(.allowOnce)
                return
            }
            if !command.isEmpty && BashSafety.isReadOnly(command) {
                respond(.allowOnce)
                return
            }
        }

        var responded = false
        pendingApproval = PendingApproval(
            toolName: toolName, summary: summary, input: input,
            respond: { [weak self] decision in
                guard !responded else { return }
                responded = true
                if case .allowAlways = decision, !dangerous {
                    self?.settings.alwaysAllowed.append(key)
                }
                self?.pendingApproval = nil
                respond(decision)
            }
        )
    }

    nonisolated static func allowKey(toolName: String, input: JSONValue) -> String {
        if toolName == "bash", let cmd = input["command"]?.stringValue {
            let firstToken = cmd.split(separator: " ").first.map(String.init) ?? cmd
            return "bash:\(firstToken)"
        }
        return toolName
    }

    // MARK: Sessions

    func refreshSessions() {
        sessions = ((try? store.listSessions()) ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func newSession() {
        if isRunning { stopRun() }
        if currentSessionId != nil { persistCurrentSession() }
        currentSessionId = UUID()
        messages = []
        currentTodos = []
        displayHints = [:]
        lastError = nil
        toolSession = ToolSessionState()
    }

    func selectSession(_ id: UUID) {
        guard id != currentSessionId else { return }
        if isRunning { stopRun() }
        if currentSessionId != nil { persistCurrentSession() }
        guard let record = ((try? store.load(id: id)) ?? nil) else { return }
        currentSessionId = record.id
        messages = record.messages
        currentTodos = []
        displayHints = [:]
        lastError = nil
        toolSession = ToolSessionState()
        settings.workspaceRoot = record.workspaceRoot
    }

    func deleteSession(_ id: UUID) {
        try? store.delete(id: id)
        refreshSessions()
        if id == currentSessionId {
            currentSessionId = nil
            if let latest = sessions.first {
                selectSession(latest.id)
            } else {
                newSession()
            }
        }
    }

    func persistCurrentSession() {
        guard let id = currentSessionId, !messages.isEmpty else { return }
        let title = messages.first(where: { $0.role == .user })
            .map { String($0.plainText.prefix(48)) } ?? "New Session"
        let existing = ((try? store.load(id: id)) ?? nil)
        let record = SessionRecord(
            id: id,
            title: title.isEmpty ? "New Session" : title,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date(),
            workspaceRoot: settings.workspaceRoot,
            model: settings.model,
            messages: messages
        )
        try? store.save(record)
        refreshSessions()
    }

    // MARK: Providers / key management

    var activeProvider: Provider? {
        if let id = settings.primaryProviderId,
           let match = providers.first(where: { $0.id.uuidString == id }) {
            return match
        }
        return providers.first
    }

    /// Accepts one or many keys (newline/comma/space separated), auto-
    /// detects the format of each, and appends new providers. `baseURL`
    /// and `model` override the detected defaults (for OpenAI-compatible
    /// services such as DeepSeek).
    func addKeys(_ pasted: String, baseURL: String? = nil, model: String? = nil) {
        let keys = pasted
            .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 8 }
        guard !keys.isEmpty else { return }
        for key in keys where !providers.contains(where: { $0.apiKey == key }) {
            providers.append(Provider.detect(fromKey: key, baseURL: baseURL, model: model))
        }
        persistProviders()
    }

    func saveApiKey(_ pasted: String) {
        addKeys(pasted)
    }

    func deleteProvider(_ id: UUID) {
        providers.removeAll { $0.id == id }
        if settings.primaryProviderId == id.uuidString {
            settings.primaryProviderId = nil
        }
        persistProviders()
    }

    func persistProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            try? keychain.setProvidersData(data)
        }
        refreshApiKeyPresence()
    }

    private func loadProviders() {
        if let data = ((try? keychain.getProvidersData()) ?? nil),
           let list = try? JSONDecoder().decode([Provider].self, from: data) {
            providers = list
        }
        // Migrate the pre-provider single Anthropic key (also covers the
        // ANTHROPIC_API_KEY env fallback).
        if providers.isEmpty,
           let legacy = ((try? keychain.getApiKey()) ?? nil), !legacy.isEmpty {
            providers = [Provider.detect(fromKey: legacy)]
            if let data = try? JSONEncoder().encode(providers) {
                try? keychain.setProvidersData(data)
            }
        }
    }

    func refreshApiKeyPresence() {
        apiKeyPresent = providers.contains { !$0.apiKey.isEmpty }
    }

    func setWorkspace(_ url: URL) {
        settings.workspaceRoot = url.path
    }

    private static let settingsKey = "forge.settings.v1"

    private static func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }
}

// MARK: - Approval broker bridging engine (any thread) → AppState (main)

// @unchecked: the only mutable state is a weak reference, which is atomic.
final class AppApprovalBroker: ApprovalBroker, @unchecked Sendable {
    private weak var state: AppState?

    init(state: AppState) {
        self.state = state
    }

    func requestApproval(toolName: String, summary: String, input: JSONValue) async -> ApprovalDecision {
        guard let state else { return .deny }
        return await withCheckedContinuation { cont in
            Task { @MainActor in
                state.presentApproval(toolName: toolName, summary: summary, input: input) { decision in
                    cont.resume(returning: decision)
                }
            }
        }
    }
}

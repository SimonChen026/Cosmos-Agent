import Foundation
import SwiftUI

// =====================================================================
// AppState — the integration hub. Owned by the scaffold (do not rewrite;
// builders may only read this file to learn the surface they target).
// =====================================================================

struct AppSettings: Codable, Equatable {
    var model: String = ModelCatalog.defaultModel
    var maxTurns: Int = 50
    var permissionLevel: PermissionLevel = .askEveryTime
    var workspaceRoot: String = NSHomeDirectory()
    var thinkingMode: String = "adaptive"
    /// Persisted "always allow" keys: a tool name ("edit_file") or a
    /// bash first-token rule ("bash:npm").
    var alwaysAllowed: [String] = []
    /// UUID string of the provider the main agent uses (subagents rotate
    /// across all providers). Nil → first provider.
    var primaryProviderId: String?
    /// LLM-judge difficulty routing: classify each user message with the
    /// fastest configured model and pick a provider of the matching tier
    /// automatically.
    var autoRoute: Bool = true
    /// "system" | "light" | "dark" — consumed by the appearance toggle in Settings.
    var appearance: String = "system"
    /// Top-level Cowork / Chat / Code mode — Cowork is the default landing tab.
    var mode: AppMode = .cowork
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
    /// Set while a run is using a difficulty-routed provider that differs
    /// from the pinned primary — lets the composer's model picker show the
    /// model actually handling this turn (proves routing swaps the real
    /// model, not just a hidden effort dial), then clears when the run ends.
    @Published var routedProviderId: UUID?
    @Published var apiKeyPresent = false
    @Published var providers: [Provider] = []
    /// Drives the in-window Settings sheet (also reachable via ⌘,).
    @Published var showingSettings = false
    @Published var currentTodos: [TodoItem] = []
    /// Rich render payloads keyed by toolUseId (diffs etc.) — display-only,
    /// not persisted with the transcript.
    @Published var displayHints: [String: DisplayHint] = [:]
    /// Artifacts created/updated via `create_artifact` — display-only, reset
    /// on every new/switched session so nothing leaks across conversations.
    @Published var artifacts: [Artifact] = []
    @Published var selectedArtifactId: String?
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
    /// Sessions currently generating a smart title — prevents firing a
    /// second concurrent call for the same session.
    private var titleGenerationInFlight: Set<UUID> = []

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

    func send(_ text: String, images: [(mediaType: String, base64: String)] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty, !isRunning else { return }
        guard apiKeyPresent else {
            lastError = "No API key configured. Open Settings (⌘,) and paste your Anthropic API key."
            return
        }
        lastError = nil

        if !images.isEmpty, !(activeProvider?.supportsVision ?? false) {
            if let visionProvider = providers.first(where: { $0.supportsVision }) {
                settings.primaryProviderId = visionProvider.id.uuidString
                statusText = "Switched to \(visionProvider.name) · \(visionProvider.model) for image support"
            } else {
                lastError = "No configured provider supports images. Add a vision-capable model in Settings (⌘,)."
                return
            }
        }

        var blocks: [ContentBlock] = images.map { .image(mediaType: $0.mediaType, base64: $0.base64) }
        if !trimmed.isEmpty { blocks.append(.text(trimmed)) }
        messages.append(ChatMessage(role: .user, blocks: blocks))
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
        guard let provider = activeProvider else {
            lastError = "No API key configured. Paste one on the start screen or in Settings (⌘,)."
            return
        }
        let lastUser = messages.last(where: { $0.role == .user })?.plainText
        isRunning = true
        statusText = "thinking…"
        runGeneration += 1
        let generation = runGeneration
        let sessionAtStart = currentSessionId
        let broker = AppApprovalBroker(state: self)
        let engine = self.engine
        let allProviders = providers
        let runMessages = messages
        let settingsAtStart = settings
        let workspacePath = workspaceURL.path

        runTask = Task { [weak self] in
            var routedProvider = provider
            var extraSystemNote = ""

            // LLM-judge difficulty routing: a cheap classification call
            // through the fastest configured model picks the tier for the
            // real turn, and hints the agent tool when the request looks
            // like independent sub-tasks.
            if settingsAtStart.autoRoute, allProviders.count > 1, let lastUser {
                let judge = allProviders.first(where: { $0.tier == "fast" }) ?? allProviders[0]
                let result = await DifficultyRouter.classify(message: lastUser, judge: judge, engine: engine)
                guard let self, self.runGeneration == generation else { return }
                if let routed = DifficultyRouter.candidates(tier: result.tier, from: allProviders).first {
                    routedProvider = routed
                    self.statusText = "difficulty: \(result.tier) → \(routed.name) · \(routed.model)"
                    if routed.id != provider.id { self.routedProviderId = routed.id }
                }
                if result.suggestsMultiAgent {
                    extraSystemNote = "\n\nNote: this request may contain independent sub-tasks — consider delegating pieces to the agent tool."
                }
            }
            guard let self, self.runGeneration == generation else { return }

            var config = AgentConfig()
            config.apiKey = routedProvider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            // Trim so a stray space/newline in the model or URL can never
            // reach the API (a frequent cause of 400 "unsupported model" errors).
            config.model = routedProvider.model.trimmingCharacters(in: .whitespacesAndNewlines)
            config.providerKind = routedProvider.kind
            config.baseURL = routedProvider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            config.temperature = routedProvider.temperature
            config.topP = routedProvider.topP
            config.maxTokens = routedProvider.maxTokens
            config.maxTurns = settingsAtStart.maxTurns
            config.workspaceRoot = workspacePath
            config.thinkingMode = settingsAtStart.thinkingMode

            let request = AgentRunRequest(
                messages: runMessages,
                systemPrompt: buildSystemPrompt(workspaceRoot: workspacePath, model: routedProvider.model) + extraSystemNote,
                config: config,
                tools: self.tools,
                session: self.toolSession,
                providers: allProviders
            )
            for await event in engine.run(request, approval: broker) {
                guard self.runGeneration == generation,
                      self.currentSessionId == sessionAtStart else { continue }
                self.handle(event)
            }
            guard self.runGeneration == generation else { return }
            self.isRunning = false
            self.statusText = nil
            self.routedProviderId = nil
            if self.currentSessionId == sessionAtStart {
                self.persistCurrentSession()
                self.maybeGenerateSmartTitle(for: sessionAtStart)
            }
        }
    }

    // MARK: Event folding

    /// Test-only seam exposing event folding without a full engine run.
    func handleForTest(_ event: AgentEvent) {
        handle(event)
    }

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
            if case .artifact(let id, let title, let kind, let language, let content)? = output.displayHint {
                let artifact = Artifact(id: id, title: title, kind: kind, language: language,
                                        content: content, updatedAt: Date())
                if let i = artifacts.firstIndex(where: { $0.id == id }) {
                    artifacts[i] = artifact
                } else {
                    artifacts.append(artifact)
                }
                selectedArtifactId = id
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
        let permissionClass = tools.first(where: { $0.spec.name == toolName })?.permissionClass

        if settings.permissionLevel == .readOnly, permissionClass != .read {
            respond(.deny)
            return
        }

        let key = Self.allowKey(toolName: toolName, input: input)
        let command = (toolName == "bash") ? (input["command"]?.stringValue ?? "") : ""

        let dangerous = !command.isEmpty && BashSafety.isDangerous(command)
        let autoByLevel: Bool
        switch settings.permissionLevel {
        case .readOnly, .askEveryTime:
            autoByLevel = false
        case .acceptEdits:
            autoByLevel = permissionClass == .write
        case .acceptAll:
            autoByLevel = permissionClass == .write || permissionClass == .execute
        case .bypassAll:
            autoByLevel = true
        }

        if !dangerous || settings.permissionLevel == .bypassAll {
            if autoByLevel
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
        artifacts = []
        selectedArtifactId = nil
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
        artifacts = []
        selectedArtifactId = nil
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

    /// User-driven rename. Once set, this title survives every future
    /// auto-save (persistCurrentSession no longer overwrites it with the
    /// first-message heuristic).
    func renameSession(_ id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var record = ((try? store.load(id: id)) ?? nil) else { return }
        record.title = trimmed
        record.customTitle = trimmed
        try? store.save(record)
        refreshSessions()
    }

    func persistCurrentSession() {
        guard let id = currentSessionId, !messages.isEmpty else { return }
        let existing = ((try? store.load(id: id)) ?? nil)
        let title: String
        if let custom = existing?.customTitle {
            title = custom
        } else {
            let auto = messages.first(where: { $0.role == .user })
                .map { String($0.plainText.prefix(48)) } ?? "New Session"
            title = auto.isEmpty ? "New Session" : auto
        }
        let record = SessionRecord(
            id: id,
            title: title,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date(),
            workspaceRoot: settings.workspaceRoot,
            model: settings.model,
            messages: messages,
            customTitle: existing?.customTitle
        )
        try? store.save(record)
        refreshSessions()
    }

    /// After the first exchange (one user message + one assistant reply)
    /// completes, replace the crude "first 48 characters" title with a real
    /// summary via a cheap call to the fastest configured model — skipped
    /// if the user already renamed the session (customTitle always wins)
    /// or a generation is already in flight for it.
    private func maybeGenerateSmartTitle(for id: UUID?) {
        guard let id, !titleGenerationInFlight.contains(id) else { return }
        guard let record = ((try? store.load(id: id)) ?? nil), record.customTitle == nil else { return }
        guard let firstUser = record.messages.first(where: { $0.role == .user && !$0.plainText.isEmpty }),
              let firstReply = record.messages.first(where: { $0.role == .assistant && !$0.plainText.isEmpty })
        else { return }
        guard let judge = providers.first(where: { $0.tier == "fast" }) ?? providers.first else { return }

        titleGenerationInFlight.insert(id)
        let exchange = "User: \(firstUser.plainText)\nAssistant: \(firstReply.plainText)"
        let engine = self.engine
        Task { [weak self] in
            let title = await SessionTitler.summarize(exchange: exchange, judge: judge, engine: engine)
            guard let self else { return }
            self.titleGenerationInFlight.remove(id)
            guard let title else { return }
            guard var current = ((try? self.store.load(id: id)) ?? nil), current.customTitle == nil else { return }
            current.title = title
            current.customTitle = title
            try? self.store.save(current)
            self.refreshSessions()
        }
    }

    // MARK: Providers / key management

    var activeProvider: Provider? {
        if let id = settings.primaryProviderId,
           let match = providers.first(where: { $0.id.uuidString == id }) {
            return match
        }
        return providers.first
    }

    /// A credential (key + endpoint), which may expose several models. This
    /// is a UI grouping over the flat `providers` list; each (account, model)
    /// pair is still one `Provider` — the atom the router and subagents use.
    struct ProviderAccount: Identifiable {
        let id: String            // kind | baseURL | apiKey
        let name: String
        let kind: String
        let baseURL: String
        let apiKey: String
        let models: [Provider]
    }

    var accounts: [ProviderAccount] {
        var order: [String] = []
        var groups: [String: [Provider]] = [:]
        for p in providers {
            let key = "\(p.kind)\u{1}\(p.baseURL)\u{1}\(p.apiKey)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(p)
        }
        return order.map { key in
            let ps = groups[key]!
            return ProviderAccount(id: key, name: ps[0].name, kind: ps[0].kind,
                                   baseURL: ps[0].baseURL, apiKey: ps[0].apiKey, models: ps)
        }
    }

    /// Default routing tier for a Claude model.
    static func defaultTier(forModel model: String) -> String {
        let m = model.lowercased()
        if m.contains("haiku") { return "fast" }
        if m.contains("opus") || m.contains("fable") { return "strong" }
        return "balanced"
    }

    /// Accepts one or many keys (newline/comma/space separated), auto-
    /// detects the format of each, and registers providers. An Anthropic
    /// key expands to ALL Claude models at once (one key → every model);
    /// an OpenAI-compatible key registers one model (add more per account
    /// afterwards). `baseURL`/`model` override detected defaults.
    func addKeys(_ pasted: String, baseURL: String? = nil, model: String? = nil) {
        let keys = pasted
            .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 8 }
        guard !keys.isEmpty else { return }
        for key in keys {
            if key.hasPrefix("sk-ant-") {
                for entry in ModelCatalog.models
                where !providers.contains(where: { $0.apiKey == key && $0.model == entry.id }) {
                    var p = Provider.detect(fromKey: key)
                    p.model = entry.id
                    p.tier = Self.defaultTier(forModel: entry.id)
                    providers.append(p)
                }
            } else if !providers.contains(where: {
                $0.apiKey == key && $0.model == (model ?? "")
            }) || (model?.isEmpty ?? true) {
                let candidate = Provider.detect(fromKey: key, baseURL: baseURL, model: model)
                if !providers.contains(where: {
                    $0.apiKey == candidate.apiKey && $0.baseURL == candidate.baseURL
                        && $0.model == candidate.model
                }) {
                    providers.append(candidate)
                }
            }
        }
        persistProviders()
    }

    func saveApiKey(_ pasted: String) {
        addKeys(pasted)
    }

    /// Adds another model under an existing account (shares its credential).
    func addModel(to account: ProviderAccount, model: String) {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return }
        guard !providers.contains(where: {
            $0.kind == account.kind && $0.baseURL == account.baseURL
                && $0.apiKey == account.apiKey && $0.model == m
        }) else { return }
        providers.append(Provider(
            name: account.name, kind: account.kind, baseURL: account.baseURL,
            model: m, apiKey: account.apiKey,
            tier: Self.defaultTier(forModel: m)))
        persistProviders()
    }

    /// Fetches the model list from an OpenAI-compatible `/models` endpoint.
    /// Best-effort: returns [] on any failure so the UI can fall back to
    /// manual entry.
    func fetchModels(for account: ProviderAccount) async -> [String] {
        let base = account.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = account.kind == "anthropic" ? "/v1/models" : "/models"
        guard let url = URL(string: base + path) else { return [] }
        var req = URLRequest(url: url)
        if account.kind == "anthropic" {
            req.setValue(account.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(account.apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let json = try JSONValue.parse(data)
            let ids = (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
            return Array(Set(ids)).sorted()
        } catch {
            return []
        }
    }

    func deleteProvider(_ id: UUID) {
        providers.removeAll { $0.id == id }
        if settings.primaryProviderId == id.uuidString {
            settings.primaryProviderId = nil
        }
        persistProviders()
    }

    /// Removes every model under one credential.
    func deleteAccount(_ account: ProviderAccount) {
        providers.removeAll {
            $0.kind == account.kind && $0.baseURL == account.baseURL && $0.apiKey == account.apiKey
        }
        if let pid = settings.primaryProviderId,
           !providers.contains(where: { $0.id.uuidString == pid }) {
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

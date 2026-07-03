import Foundation

// =====================================================================
// Shared contracts. Every module compiles against the types in this
// file. DO NOT change signatures here without updating SPEC.md — four
// parallel builders depend on exact names.
// =====================================================================

// MARK: - Messages

enum Role: String, Codable, Sendable {
    case user
    case assistant
}

/// A content block, mirroring the Anthropic Messages API block kinds.
enum ContentBlock: Equatable, Sendable {
    case text(String)
    /// Thinking blocks must be replayed byte-identical (with signature) when
    /// echoing assistant turns back to the API.
    case thinking(String, signature: String?)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: String, isError: Bool)
}

extension ContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, text, signature, id, name, input, toolUseId, content, isError
    }
    private enum Kind: String, Codable { case text, thinking, toolUse, toolResult }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try c.decode(String.self, forKey: .text))
        case .thinking:
            self = .thinking(
                try c.decode(String.self, forKey: .text),
                signature: try c.decodeIfPresent(String.self, forKey: .signature)
            )
        case .toolUse:
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                input: try c.decode(JSONValue.self, forKey: .input)
            )
        case .toolResult:
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .toolUseId),
                content: try c.decode(String.self, forKey: .content),
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(t, forKey: .text)
        case .thinking(let t, let sig):
            try c.encode(Kind.thinking, forKey: .kind)
            try c.encode(t, forKey: .text)
            try c.encodeIfPresent(sig, forKey: .signature)
        case .toolUse(let id, let name, let input):
            try c.encode(Kind.toolUse, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let content, let isError):
            try c.encode(Kind.toolResult, forKey: .kind)
            try c.encode(toolUseId, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
            try c.encode(isError, forKey: .isError)
        }
    }
}

struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var role: Role
    var blocks: [ContentBlock]
    var timestamp: Date

    init(id: UUID = UUID(), role: Role, blocks: [ContentBlock], timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
    }

    /// Concatenated plain text of all text blocks.
    var plainText: String {
        blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined(separator: "\n")
    }
}

// MARK: - Todos

enum TodoStatus: String, Codable, Sendable {
    case pending, inProgress, completed
}

struct TodoItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var text: String
    var status: TodoStatus
}

// MARK: - Tools

enum PermissionClass: String, Codable, Sendable {
    /// Auto-approved (read-only operations).
    case read
    /// Mutates the file system — gated behind approval.
    case write
    /// Executes arbitrary code — gated behind approval.
    case execute
}

struct ToolSpec: Sendable {
    let name: String
    let description: String
    /// JSON Schema object describing the input.
    let inputSchema: JSONValue
}

/// Mutable per-session state shared by tools (thread-safe).
final class ToolSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var readPaths: Set<String> = []
    private var todoItems: [TodoItem] = []

    func markRead(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        readPaths.insert(path)
    }

    func wasRead(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return readPaths.contains(path)
    }

    var todos: [TodoItem] {
        get { lock.lock(); defer { lock.unlock() }; return todoItems }
        set { lock.lock(); defer { lock.unlock() }; todoItems = newValue }
    }
}

struct ToolContext: Sendable {
    /// Directory the agent operates in. Relative paths resolve against this.
    var workspaceRoot: URL
    var session: ToolSessionState
    /// The run's approval broker — lets tools that spawn subagents route
    /// the subagent's write/execute approvals to the same UI.
    var approval: (any ApprovalBroker)?
    /// Configured providers, for tools that spawn subagents (key rotation).
    var providers: [Provider]

    init(workspaceRoot: URL, session: ToolSessionState,
         approval: (any ApprovalBroker)? = nil, providers: [Provider] = []) {
        self.workspaceRoot = workspaceRoot
        self.session = session
        self.approval = approval
        self.providers = providers
    }
}

// MARK: - Providers

/// One API credential + endpoint + model. `kind` selects the wire format;
/// `tier` is the capability class the difficulty router targets.
struct Provider: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    /// "anthropic" or "openai" (OpenAI-compatible Chat Completions).
    var kind: String
    var baseURL: String
    var model: String
    var apiKey: String
    /// "fast" | "balanced" | "strong" — used by difficulty routing.
    var tier: String
    /// Sampling controls sent with every request from this provider.
    var temperature: Double
    var topP: Double
    var maxTokens: Int

    init(id: UUID = UUID(), name: String, kind: String, baseURL: String,
         model: String, apiKey: String, tier: String = "balanced",
         temperature: Double = 1.0, topP: Double = 1.0, maxTokens: Int = 16_384) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.tier = tier
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }

    // Manual decoding so provider blobs saved by older builds (without the
    // tuning fields) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        model = try c.decode(String.self, forKey: .model)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        tier = try c.decodeIfPresent(String.self, forKey: .tier) ?? "balanced"
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 1.0
        topP = try c.decodeIfPresent(Double.self, forKey: .topP) ?? 1.0
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 16_384
    }

    /// Builds a provider from a pasted key, auto-detecting the format.
    /// Optional overrides apply when the user supplied an endpoint/model.
    static func detect(fromKey key: String, baseURL: String? = nil,
                       model: String? = nil) -> Provider {
        var provider: Provider
        if key.hasPrefix("sk-ant-") {
            provider = Provider(name: "Anthropic", kind: "anthropic",
                                baseURL: "https://api.anthropic.com",
                                model: ModelCatalog.defaultModel, apiKey: key)
        } else {
            provider = Provider(name: "OpenAI-compatible", kind: "openai",
                                baseURL: "https://api.openai.com/v1",
                                model: "gpt-4o", apiKey: key)
        }
        if let baseURL, !baseURL.isEmpty, provider.kind == "openai" {
            provider.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
            if let host = URL(string: provider.baseURL)?.host {
                provider.name = host.replacingOccurrences(of: "api.", with: "")
            }
        }
        if let model, !model.isEmpty {
            provider.model = model
        }
        return provider
    }
}

/// One difficulty-routing rule: if `pattern` (regex) matches the user's
/// message, the run is routed to a provider of `tier`.
struct RoutingRule: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var pattern: String
    var tier: String

    init(id: UUID = UUID(), pattern: String, tier: String) {
        self.id = id
        self.pattern = pattern
        self.tier = tier
    }

    static let defaults: [RoutingRule] = [
        RoutingRule(
            pattern: #"(?i)(refactor|architect|design|debug|optimi[sz]e|race condition|deadlock|security|vulnerab|prove|algorithm|complexit|migrat|concurren|重构|架构|设计|调试|优化|并发|死锁|安全|算法|证明|迁移|复杂)"#,
            tier: "strong"),
        RoutingRule(
            pattern: #"(?i)^\s*(what|who|when|where|list|show|print|read|cat|explain|translate|rename|typo|summari|什么|谁|哪|列出|看看|读一?下|翻译|解释|改名|总结)"#,
            tier: "fast"),
    ]
}

/// Optional structured payload so the UI can render rich cards (diffs etc.).
enum DisplayHint: Equatable, Sendable, Codable {
    case diff(path: String, old: String, new: String)
    case fileContent(path: String)
    case commandOutput(command: String)
    case todoList(items: [TodoItem])
}

struct ToolOutput: Sendable {
    var content: String
    var isError: Bool
    var displayHint: DisplayHint?

    init(content: String, isError: Bool = false, displayHint: DisplayHint? = nil) {
        self.content = content
        self.isError = isError
        self.displayHint = displayHint
    }

    static func error(_ message: String) -> ToolOutput {
        ToolOutput(content: message, isError: true)
    }
}

protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    var permissionClass: PermissionClass { get }
    /// One-line human-readable summary of what this specific call will do,
    /// e.g. "$ npm test" or "edit src/main.swift". Shown in approval UI and chat.
    func summarize(input: JSONValue) -> String
    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput
}

// MARK: - Approval

enum ApprovalDecision: Sendable {
    case allowOnce
    case allowAlways
    case deny
}

/// Implemented by the app layer; the engine calls this before running any
/// tool whose permissionClass is not `.read` (in every mode — the broker
/// itself applies auto-approve / allowlist policy and may return instantly).
protocol ApprovalBroker: Sendable {
    func requestApproval(toolName: String, summary: String, input: JSONValue) async -> ApprovalDecision
}

// MARK: - Engine

struct AgentConfig: Codable, Equatable, Sendable {
    var apiKey: String = ""
    var model: String = "claude-sonnet-5"
    /// "anthropic" or "openai" — selects request format and endpoint path.
    var providerKind: String = "anthropic"
    var baseURL: String = "https://api.anthropic.com"
    var maxTokens: Int = 16_384
    /// Sampling controls (Anthropic clamps temperature to 0…1 on send).
    var temperature: Double = 1.0
    var topP: Double = 1.0
    var maxTurns: Int = 50
    var workspaceRoot: String = NSHomeDirectory()
    var autoApprove: Bool = false
    /// "adaptive" or "off".
    var thinkingMode: String = "adaptive"
    /// Approximate input-token budget; two-stage compaction below this.
    var contextTokenBudget: Int = 160_000
}

struct AgentRunRequest {
    var messages: [ChatMessage]
    var systemPrompt: String
    var config: AgentConfig
    var tools: [any AgentTool]
    var session: ToolSessionState
    /// All configured providers — subagents rotate across these.
    var providers: [Provider] = []
}

enum RunEndReason: Equatable, Sendable {
    case completed
    case maxTurnsReached
    case cancelled
    case failed(String)
}

/// Events streamed from the engine to the UI layer. Display-oriented;
/// the authoritative transcript arrives with `.runFinished`.
enum AgentEvent: Sendable {
    case messageStarted(id: UUID, role: Role)
    case textDelta(messageId: UUID, delta: String)
    case thinkingDelta(messageId: UUID, delta: String)
    case toolCallStarted(messageId: UUID, toolUseId: String, name: String)
    /// Input JSON fully accumulated and parsed.
    case toolCallReady(messageId: UUID, toolUseId: String, name: String, input: JSONValue, summary: String)
    case toolResult(toolUseId: String, name: String, output: ToolOutput)
    case usage(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int)
    /// Non-fatal notices (e.g. "compacted 12 old messages").
    case info(String)
    case runFinished(messages: [ChatMessage], reason: RunEndReason)
}

protocol AgentEngineProtocol: AnyObject, Sendable {
    /// Runs the agent loop until the model stops requesting tools, an error
    /// occurs, maxTurns is hit, or `cancel()` is called. The stream always
    /// terminates with exactly one `.runFinished` event.
    func run(_ request: AgentRunRequest, approval: any ApprovalBroker) -> AsyncStream<AgentEvent>
    func cancel()
}

// MARK: - Persistence

struct SessionRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var workspaceRoot: String
    var model: String
    var messages: [ChatMessage]

    init(id: UUID = UUID(), title: String = "New Session", createdAt: Date = Date(),
         updatedAt: Date = Date(), workspaceRoot: String, model: String,
         messages: [ChatMessage] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.workspaceRoot = workspaceRoot
        self.model = model
        self.messages = messages
    }
}

protocol SessionStoreProtocol: Sendable {
    func listSessions() throws -> [SessionRecord]
    func load(id: UUID) throws -> SessionRecord?
    func save(_ session: SessionRecord) throws
    func delete(id: UUID) throws
}

protocol KeychainProtocol: Sendable {
    func getApiKey() throws -> String?
    func setApiKey(_ key: String) throws
    func deleteApiKey() throws
    /// Whole provider list (JSON blob, keys included) — one Keychain item.
    func getProvidersData() throws -> Data?
    func setProvidersData(_ data: Data) throws
}

// MARK: - Model catalogue

enum ModelCatalog {
    static let models: [(id: String, label: String)] = [
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-opus-4-8", "Opus 4.8"),
        ("claude-fable-5", "Fable 5"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
    ]
    static let defaultModel = "claude-sonnet-5"
}

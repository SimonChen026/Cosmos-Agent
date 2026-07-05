import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var apiKeyDraft = ""
    @State private var apiKeyBaseURLDraft = ""
    @State private var apiKeyModelDraft = ""
    @State private var justSaved = false
    @State private var modelDrafts: [String: String] = [:]
    @State private var fetched: [String: [String]] = [:]
    @State private var fetching: Set<String> = []

    var body: some View {
        Form {
            Section("Providers") {
                if state.providers.isEmpty {
                    Label("No keys yet — paste one or more below.", systemImage: "key.slash")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                ForEach(state.accounts) { account in
                    accountBlock(account)
                }
                TextField("Add API keys — one per line, auto-detected",
                          text: $apiKeyDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 12, design: .monospaced))
                HStack(spacing: 8) {
                    TextField("Base URL — e.g. https://api.deepseek.com (for non-Anthropic keys)",
                              text: $apiKeyBaseURLDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    TextField("Model", text: $apiKeyModelDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 140)
                }
                Text("Chinese/other OpenAI-compatible vendors (DeepSeek, Kimi, Zhipu…) need Base URL set here, or the key is misread as an OpenAI key and fails.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text("An Anthropic key adds every Claude model automatically. The primary model drives the main agent; subagents rotate across models within each difficulty tier.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(justSaved ? "Added" : "Add Keys") {
                        saveKey()
                    }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .controlSize(.small)
                }
                Picker("Extended thinking (Anthropic)", selection: $state.settings.thinkingMode) {
                    Text("Adaptive").tag("adaptive")
                    Text("Off").tag("off")
                }
                .help("Adaptive lets the model think when useful; falls back automatically if the model doesn't support it.")
            }

            Section("Difficulty routing") {
                Toggle("Auto-route by difficulty", isOn: $state.settings.autoRoute)
                Text("Each message is triaged by your fastest configured model, which picks the right provider tier and, when useful, hints the agent to fan out to sub-agents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Workspace") {
                HStack {
                    Text(workspaceDisplay)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        WorkspacePicker.choose(state: state)
                    }
                }
            }

            Section("Agent") {
                Picker("Permissions", selection: $state.settings.permissionLevel) {
                    ForEach(PermissionLevel.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.menu)
                Text(state.settings.permissionLevel.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.settings.permissionLevel == .acceptAll {
                    Text("Forge will write files and run commands without asking. Clearly dangerous shell commands still require confirmation.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if state.settings.permissionLevel == .bypassAll {
                    Text("Forge will run everything without asking, including clearly dangerous commands (sudo, rm -rf, force-push, etc.). Use with caution.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Stepper("Max turns per run: \(state.settings.maxTurns)",
                        value: $state.settings.maxTurns, in: 10...100, step: 5)
                if !state.settings.alwaysAllowed.isEmpty {
                    HStack {
                        Text("Always-allowed: \(state.settings.alwaysAllowed.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button("Reset") {
                            state.settings.alwaysAllowed = []
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section {
                Text("Cosmos runs entirely on this Mac. The only network traffic goes to the API providers you configure; sessions are stored in ~/Library/Application Support/Cosmos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 700)
        .onChange(of: state.providers) { _, _ in
            state.persistProviders()
        }
    }

    private var workspaceDisplay: String {
        let path = state.workspaceURL.path
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }

    private func saveKey() {
        let keys = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keys.isEmpty else { return }
        state.addKeys(keys,
                      baseURL: apiKeyBaseURLDraft.trimmingCharacters(in: .whitespaces),
                      model: apiKeyModelDraft.trimmingCharacters(in: .whitespaces))
        apiKeyDraft = ""
        apiKeyBaseURLDraft = ""
        apiKeyModelDraft = ""
        justSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justSaved = false }
    }

    // MARK: - Account (one credential → many models)

    @ViewBuilder
    private func accountBlock(_ account: AppState.ProviderAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(account.name).fontWeight(.semibold)
                Text(account.kind)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(account.kind == "anthropic"
                        ? Color.orange.opacity(0.18) : Color.blue.opacity(0.18)))
                Text("\(account.models.count) model\(account.models.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(masked(account.apiKey))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Button(role: .destructive) {
                    state.deleteAccount(account)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this key and all its models")
            }
            if account.kind == "openai" {
                Text(account.baseURL)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ForEach(account.models) { model in
                modelRow(model)
            }
            addModelControls(account)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func modelRow(_ provider: Provider) -> some View {
        let bind = modelBinding(provider.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "cube")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("model-id", text: bind.model)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
                if state.activeProvider?.id == provider.id {
                    Label("primary", systemImage: "star.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.yellow)
                        .help("Primary — drives the main agent")
                } else {
                    Button {
                        state.settings.primaryProviderId = provider.id.uuidString
                    } label: {
                        Image(systemName: "star")
                    }
                    .buttonStyle(.borderless)
                    .help("Make primary")
                }
                Button {
                    state.deleteProvider(provider.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Remove this model")
            }
            Picker("", selection: bind.tier) {
                Text("Fast").tag("fast")
                Text("Balanced").tag("balanced")
                Text("Strong").tag("strong")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            DisclosureGroup("Tuning") {
                HStack {
                    Text("Temp").font(.caption2).frame(width: 40, alignment: .leading)
                    Slider(value: bind.temperature, in: 0...2, step: 0.1)
                    Text(String(format: "%.1f", provider.temperature))
                        .font(.caption2.monospacedDigit()).frame(width: 26)
                }
                HStack {
                    Text("Top-p").font(.caption2).frame(width: 40, alignment: .leading)
                    Slider(value: bind.topP, in: 0.05...1, step: 0.05)
                    Text(String(format: "%.2f", provider.topP))
                        .font(.caption2.monospacedDigit()).frame(width: 32)
                }
                Stepper("Max tokens: \(provider.maxTokens)",
                        value: bind.maxTokens, in: 4_096...64_000, step: 4_096)
                    .font(.caption2)
            }
            .font(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
    }

    @ViewBuilder
    private func addModelControls(_ account: AppState.ProviderAccount) -> some View {
        HStack(spacing: 8) {
            TextField("Add model id…", text: draftBinding(account.id))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            Button("Add") {
                state.addModel(to: account, model: modelDrafts[account.id] ?? "")
                modelDrafts[account.id] = ""
            }
            .controlSize(.small)
            .disabled((modelDrafts[account.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            if account.kind == "anthropic" {
                let missing = ModelCatalog.models.filter { entry in
                    !account.models.contains { $0.model == entry.id }
                }
                if !missing.isEmpty {
                    Button("Add all Claude models") {
                        for entry in missing { state.addModel(to: account, model: entry.id) }
                    }
                    .controlSize(.small)
                    .help("Add every Claude model this key can use")
                }
            }
            if account.kind == "openai" {
                Button {
                    fetching.insert(account.id)
                    Task {
                        let models = await state.fetchModels(for: account)
                        fetched[account.id] = models
                        fetching.remove(account.id)
                    }
                } label: {
                    if fetching.contains(account.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Fetch models")
                    }
                }
                .controlSize(.small)
                if let models = fetched[account.id] {
                    let addable = models.filter { m in !account.models.contains { $0.model == m } }
                    if addable.isEmpty {
                        Text("all added").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Menu("Add (\(addable.count))") {
                            ForEach(addable, id: \.self) { model in
                                Button(model) { state.addModel(to: account, model: model) }
                            }
                        }
                        .controlSize(.small)
                        .frame(maxWidth: 140)
                    }
                }
            }
        }
    }

    private func modelBinding(_ id: UUID) -> Binding<Provider> {
        Binding(
            get: {
                state.providers.first(where: { $0.id == id })
                    ?? Provider(name: "", kind: "openai", baseURL: "", model: "", apiKey: "")
            },
            set: { newValue in
                if let i = state.providers.firstIndex(where: { $0.id == id }) {
                    state.providers[i] = newValue
                }
            }
        )
    }

    private func draftBinding(_ accountId: String) -> Binding<String> {
        Binding(
            get: { modelDrafts[accountId] ?? "" },
            set: { modelDrafts[accountId] = $0 }
        )
    }

    private func masked(_ key: String) -> String {
        guard key.count > 10 else { return "••••" }
        return String(key.prefix(6)) + "…" + String(key.suffix(4))
    }
}

/// In-window presentation of Settings (a sheet from the main window). The
/// separate ⌘, Settings scene reuses `SettingsView` directly.
struct SettingsSheet: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        SettingsView()
            .overlay(alignment: .topTrailing) {
                Button {
                    state.showingSettings = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            }
    }
}

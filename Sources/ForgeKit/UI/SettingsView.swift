import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var apiKeyDraft = ""
    @State private var justSaved = false

    var body: some View {
        Form {
            Section("Providers") {
                if state.providers.isEmpty {
                    Label("No keys yet — paste one or more below.", systemImage: "key.slash")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                ForEach($state.providers) { $provider in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(provider.name).fontWeight(.medium)
                            Text(provider.kind)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(
                                    provider.kind == "anthropic"
                                        ? Color.orange.opacity(0.18)
                                        : Color.blue.opacity(0.18)))
                            Spacer()
                            if state.activeProvider?.id == provider.id {
                                Label("primary", systemImage: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.yellow)
                            } else {
                                Button("Make Primary") {
                                    state.settings.primaryProviderId = provider.id.uuidString
                                }
                                .controlSize(.small)
                            }
                            Button {
                                state.deleteProvider(provider.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                        TextField("Model", text: $provider.model)
                            .font(.system(size: 12, design: .monospaced))
                        TextField("Base URL", text: $provider.baseURL)
                            .font(.system(size: 12, design: .monospaced))
                        Picker("Tier", selection: $provider.tier) {
                            Text("Fast").tag("fast")
                            Text("Balanced").tag("balanced")
                            Text("Strong").tag("strong")
                        }
                        .pickerStyle(.segmented)
                        .help("The difficulty router sends easy questions to fast providers and hard ones to strong providers.")
                        HStack {
                            Text("Temperature")
                                .font(.caption)
                            Slider(value: $provider.temperature, in: 0...2, step: 0.1)
                            Text(String(format: "%.1f", provider.temperature))
                                .font(.caption.monospacedDigit())
                                .frame(width: 28)
                        }
                        HStack {
                            Text("Top-p")
                                .font(.caption)
                            Slider(value: $provider.topP, in: 0.05...1, step: 0.05)
                            Text(String(format: "%.2f", provider.topP))
                                .font(.caption.monospacedDigit())
                                .frame(width: 34)
                        }
                        Stepper("Max output tokens: \(provider.maxTokens)",
                                value: $provider.maxTokens, in: 4_096...64_000, step: 4_096)
                            .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
                TextField("Add keys — one per line, auto-detected",
                          text: $apiKeyDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 12, design: .monospaced))
                HStack {
                    Text("The primary provider drives the main agent; subagents rotate across all keys.")
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
                Toggle("Route by difficulty (regex rules)", isOn: $state.settings.autoRoute)
                Text("Each message is matched against the rules below, top to bottom; the first hit picks the provider tier. No hit → length/code heuristics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach($state.settings.routingRules) { $rule in
                    HStack(spacing: 8) {
                        TextField("Regex", text: $rule.pattern)
                            .font(.system(size: 11, design: .monospaced))
                        Picker("", selection: $rule.tier) {
                            Text("Fast").tag("fast")
                            Text("Balanced").tag("balanced")
                            Text("Strong").tag("strong")
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Button {
                            state.settings.routingRules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                }
                HStack {
                    Button("Add Rule") {
                        state.settings.routingRules.append(
                            RoutingRule(pattern: "(?i)example", tier: "strong"))
                    }
                    .controlSize(.small)
                    Button("Restore Defaults") {
                        state.settings.routingRules = RoutingRule.defaults
                    }
                    .controlSize(.small)
                    Spacer()
                }
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
                Toggle("Auto-approve all tool calls", isOn: $state.settings.autoApprove)
                if state.settings.autoApprove {
                    Text("Forge will write files and run commands without asking. Clearly dangerous shell commands still require confirmation.")
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
        state.saveApiKey(keys)
        apiKeyDraft = ""
        justSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justSaved = false }
    }
}

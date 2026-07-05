import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct InputBar: View {
    @EnvironmentObject var state: AppState
    @State private var draft = ""
    @State private var pendingImages: [PendingImage] = []
    @FocusState private var focused: Bool

    struct PendingImage: Identifiable {
        let id = UUID()
        let mediaType: String
        let base64: String
    }

    var body: some View {
        VStack(spacing: 4) {
            if state.isRunning, let status = state.statusText {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
            if !pendingImages.isEmpty {
                HStack(spacing: 8) {
                    ForEach(pendingImages) { image in
                        pendingImageChip(image)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
            }
            VStack(spacing: 0) {
                TextField("Ask Cosmos anything…  (⇧↩ for a new line)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.proseBody)
                    .lineLimit(1...8)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            draft += "\n"
                            return .handled
                        }
                        return .ignored
                    }
                    .onSubmit(send)
                    .onPasteCommand(of: [.tiff, .png]) { providers in
                        loadPastedImages(providers)
                    }

                HStack(alignment: .center, spacing: 8) {
                    Button {
                        chooseImageFile()
                    } label: {
                        Image(systemName: "paperclip")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("Attach an image")

                    if state.settings.mode != .code {
                        ChatCoworkSwitch()
                    }

                    PermissionLevelPicker()

                    Spacer()

                    ModelPickerMenu()

                    if state.isRunning {
                        Button {
                            state.stopRun()
                        } label: {
                            Image(systemName: "stop.fill")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .help("Stop the current run")
                    } else {
                        Button(action: send) {
                            Image(systemName: "paperplane.fill")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty)
                        .help("Send (↩)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .centeredContentColumn()
        .onChange(of: state.composerSeed) { _, seed in
            guard let seed else { return }
            draft = seed
            state.composerSeed = nil
            focused = true
        }
        .onChange(of: state.isRunning) { _, running in
            if !running { focused = true }
        }
        .onAppear { focused = true }
    }

    private func pendingImageChip(_ image: PendingImage) -> some View {
        ZStack(alignment: .topTrailing) {
            if let data = Data(base64Encoded: image.base64), let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Button {
                pendingImages.removeAll { $0.id == image.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
        .frame(width: 44, height: 44)
    }

    /// Handles image paste via `.onPasteCommand` — the primary path for
    /// getting a clipboard screenshot/copy into the composer.
    private func loadPastedImages(_ providers: [NSItemProvider]) {
        for provider in providers {
            let type = provider.hasItemConformingToTypeIdentifier(UTType.png.identifier)
                ? UTType.png : UTType.tiff
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data, let nsImage = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    appendImage(nsImage, preferredType: type)
                }
            }
        }
    }

    /// Fallback path: NSOpenPanel for picking an image file from disk.
    private func chooseImageFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .webP]
        panel.message = "Choose an image to attach."
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url), let nsImage = NSImage(data: data) else { continue }
            appendImage(nsImage, preferredType: .png)
        }
    }

    private func appendImage(_ nsImage: NSImage, preferredType: UTType) {
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return }
        let isJPEG = preferredType == .jpeg
        let data = isJPEG
            ? rep.representation(using: .jpeg, properties: [:])
            : rep.representation(using: .png, properties: [:])
        guard let data else { return }
        pendingImages.append(PendingImage(
            mediaType: isJPEG ? "image/jpeg" : "image/png",
            base64: data.base64EncodedString()
        ))
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty,
              !state.isRunning else { return }
        draft = ""
        let images = pendingImages.map { (mediaType: $0.mediaType, base64: $0.base64) }
        pendingImages = []
        state.send(text, images: images)
    }
}

/// The small Chat/Cowork sub-toggle shown inline in the composer, next to
/// the attach button — only relevant when Home is active (hidden in Code).
private struct ChatCoworkSwitch: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 2) {
            option(.chat)
            option(.cowork)
        }
        .padding(2)
        .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
    }

    private func option(_ mode: AppMode) -> some View {
        let isSelected = state.settings.mode == mode
        return Button {
            state.settings.mode = mode
        } label: {
            Text(mode.label)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(isSelected ? Color(nsColor: .textBackgroundColor) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

/// Plain-text permission-level control shown below the composer, mirroring
/// Claude Code's own "Bypass permissions"-style indicator — always visible
/// (not just when non-default) so the level is discoverable without Settings.
private struct PermissionLevelPicker: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Menu {
            ForEach(PermissionLevel.allCases, id: \.self) { level in
                Button {
                    state.settings.permissionLevel = level
                } label: {
                    HStack {
                        Text(level.label)
                        if level == state.settings.permissionLevel {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(state.settings.permissionLevel.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(state.settings.permissionLevel.caption)
    }
}

/// The composer's model picker — lists every configured model (one entry
/// per Provider, since one API key can back several models) with a
/// checkmark on the pinned primary. While a run is using a difficulty-routed
/// provider that differs from the pin, the button shows THAT model with a
/// small spinner instead, so switching tiers visibly swaps the real model
/// rather than just tweaking an effort dial under one fixed model.
private struct ModelPickerMenu: View {
    @EnvironmentObject var state: AppState

    private var routedProvider: Provider? {
        guard state.isRunning, let id = state.routedProviderId else { return nil }
        return state.providers.first(where: { $0.id == id })
    }

    private var displayedProvider: Provider? {
        routedProvider ?? state.activeProvider
    }

    var body: some View {
        Menu {
            Text("Models")
            ForEach(state.providers) { provider in
                Button {
                    state.settings.primaryProviderId = provider.id.uuidString
                } label: {
                    HStack {
                        Text("\(ModelChoice.label(for: provider.model))")
                        Text("· \(provider.tier.capitalized)")
                            .foregroundStyle(.secondary)
                        if provider.id == state.activeProvider?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if state.providers.isEmpty {
                Text("No models configured")
            }
            Divider()
            Button("More models…") { state.showingSettings = true }
        } label: {
            HStack(spacing: 5) {
                if routedProvider != nil {
                    ProgressView().controlSize(.mini)
                }
                Text(displayedProvider.map { ModelChoice.label(for: $0.model) } ?? "No model")
                    .font(.caption)
                if let tier = displayedProvider?.tier {
                    Text(tier.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model for this conversation — click to switch, or see routing in action while a reply streams")
    }
}

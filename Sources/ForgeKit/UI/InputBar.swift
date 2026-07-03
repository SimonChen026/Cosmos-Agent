import SwiftUI

struct InputBar: View {
    @EnvironmentObject var state: AppState
    @State private var draft = ""
    @FocusState private var focused: Bool

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
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Cosmos anything…  (⇧↩ for a new line)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            draft += "\n"
                            return .handled
                        }
                        return .ignored
                    }
                    .onSubmit(send)
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
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send (↩)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
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

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !state.isRunning else { return }
        draft = ""
        state.send(text)
    }
}

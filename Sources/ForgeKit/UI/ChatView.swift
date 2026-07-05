import SwiftUI

struct ChatView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if isHomeLanding {
                homeLanding
            } else {
                standardLayout
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Home (Chat/Cowork) with no conversation yet and a key already
    /// present: the greeting, composer, and quick actions center as one
    /// block instead of the composer pinning to the bottom. Code mode and
    /// any active conversation keep the standard pinned-composer layout.
    private var isHomeLanding: Bool {
        state.settings.mode != .code && state.messages.isEmpty && state.apiKeyPresent
    }

    private var homeLanding: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                HomeGreeting()
                InputBar()
                HomeQuickActions()
            }
            .centeredContentColumn()
            Spacer()
        }
    }

    private var standardLayout: some View {
        VStack(spacing: 0) {
            if state.messages.isEmpty {
                EmptyStateView()
            } else {
                transcript
            }
            VStack(spacing: 8) {
                if let error = state.lastError {
                    ErrorBanner(text: error) { state.lastError = nil }
                }
                if !state.currentTodos.isEmpty {
                    TodoPanel(items: state.currentTodos)
                }
                if let approval = state.pendingApproval {
                    ApprovalPanel(approval: approval)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            if !showsOnboarding {
                InputBar()
                Divider()
                StatusBar()
            }
        }
    }

    /// First run (no key, no history): the window shows only the key box.
    private var showsOnboarding: Bool {
        !state.apiKeyPresent && state.messages.isEmpty
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(state.messages) { message in
                        MessageRow(message: message)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .centeredContentColumn()
            }
            .onChange(of: scrollFingerprint) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Cheap change token so streaming deltas keep the view pinned to the
    /// bottom without diffing whole messages.
    private var scrollFingerprint: Int {
        var value = state.messages.count &* 31
        if let last = state.messages.last {
            value &+= last.blocks.count &* 7
            switch last.blocks.last {
            case .text(let t): value &+= t.count
            case .thinking(let t, _): value &+= t.count
            case .toolResult(_, let c, _): value &+= c.count
            default: break
            }
        }
        return value
    }
}

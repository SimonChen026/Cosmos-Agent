import SwiftUI

/// The app scene lives in ForgeKit (so the whole app is testable); the
/// thin Forge executable just calls `ForgeApp.main()`.
public struct ForgeApp: App {
    @StateObject private var state = AppState(
        engine: makeDefaultEngine(),
        tools: makeDefaultTools(),
        store: makeSessionStore(),
        keychain: makeKeychain()
    )

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { state.newSession() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

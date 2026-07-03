import Foundation

// Factory functions — the app wires itself through these.

func makeSessionStore() -> any SessionStoreProtocol {
    FileSessionStore()
}

func makeKeychain() -> any KeychainProtocol {
    KeychainStore()
}

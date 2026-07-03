import Foundation
@testable import ForgeKit

func infraTests() async {

    await test("FileSessionStore: CRUD and updatedAt ordering") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-store-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSessionStore(baseDir: dir)

        let older = SessionRecord(
            title: "older", updatedAt: Date(timeIntervalSinceNow: -100),
            workspaceRoot: "/tmp", model: "claude-sonnet-5",
            messages: [ChatMessage(role: .user, blocks: [.text("one")])])
        let newer = SessionRecord(
            title: "newer", updatedAt: Date(),
            workspaceRoot: "/tmp", model: "claude-sonnet-5",
            messages: [ChatMessage(role: .user, blocks: [.text("two")])])
        try store.save(older)
        try store.save(newer)

        let listed = try store.listSessions()
        expectEqual(listed.count, 2)
        expectEqual(listed.first?.title, "newer", "sorted by updatedAt desc")

        let loaded = try store.load(id: older.id)
        expectEqual(loaded, older)

        try store.delete(id: older.id)
        expectEqual(try store.listSessions().count, 1)
        expect(try store.load(id: older.id) == nil)
        // Deleting a missing id is a no-op, not an error.
        try store.delete(id: older.id)
    }

    await test("FileSessionStore: corrupt files are skipped") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-store-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSessionStore(baseDir: dir)

        let good = SessionRecord(title: "good", workspaceRoot: "/tmp", model: "m")
        try store.save(good)
        try Data("this is not json".utf8)
            .write(to: dir.appendingPathComponent("corrupt.json"))
        try Data("{\"half\": ".utf8)
            .write(to: dir.appendingPathComponent(UUID().uuidString + ".json"))

        let listed = try store.listSessions()
        expectEqual(listed.count, 1)
        expectEqual(listed.first?.title, "good")
    }

    await test("KeychainStore: round trip (skipped if keychain unavailable)") {
        let store = KeychainStore(service: "com.local.forge.tests")
        do {
            try store.setApiKey("sk-test-123")
            let read = try store.getApiKey()
            expectEqual(read, "sk-test-123")
            try store.setApiKey("sk-test-456")
            expectEqual(try store.getApiKey(), "sk-test-456", "update-or-add semantics")
            try store.deleteApiKey()
            // After deletion only the env fallback may remain.
            let after = try store.getApiKey()
            let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
            expectEqual(after, (env?.isEmpty ?? true) ? nil : env)
            try store.deleteApiKey()   // idempotent
        } catch {
            // CI-like contexts can deny keychain access to unsigned binaries;
            // treat as a skip, not a failure.
            print("      (keychain unavailable in this context: \(error.localizedDescription))")
            try? store.deleteApiKey()
        }
    }
}

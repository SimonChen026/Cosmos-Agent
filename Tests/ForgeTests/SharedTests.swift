import Foundation
@testable import ForgeKit

func sharedTests() async {

    await test("JSONValue round trip") {
        let value: JSONValue = [
            "name": "forge",
            "count": 3,
            "ok": true,
            "none": nil,
            "list": [1, "two", false],
            "nested": ["a": 1.5],
        ]
        let back = try JSONValue.parse(value.encodedData())
        expectEqual(back, value)
    }

    await test("JSONValue accessors") {
        let v = try JSONValue.parse(#"{"path": "/tmp/x", "limit": 42, "flag": true}"#)
        expectEqual(v["path"]?.stringValue, "/tmp/x")
        expectEqual(v["limit"]?.intValue, 42)
        expectEqual(v["flag"]?.boolValue, true)
        expect(v["missing"] == nil)
    }

    await test("ContentBlock codable round trip") {
        let blocks: [ContentBlock] = [
            .text("hello"),
            .thinking("hmm", signature: "sig123"),
            .toolUse(id: "tu_1", name: "read_file", input: ["path": "a.txt"]),
            .toolResult(toolUseId: "tu_1", content: "data", isError: false),
        ]
        let data = try JSONEncoder().encode(blocks)
        let back = try JSONDecoder().decode([ContentBlock].self, from: data)
        expectEqual(back, blocks)
    }

    await test("SessionRecord round trip") {
        let record = SessionRecord(
            workspaceRoot: "/tmp",
            model: "claude-sonnet-5",
            messages: [ChatMessage(role: .user, blocks: [.text("hi")])]
        )
        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(SessionRecord.self, from: data)
        expectEqual(back, record)
    }

    await test("resolvePath") {
        let ws = URL(fileURLWithPath: "/tmp/project")
        expectEqual(Util.resolvePath("/abs/file.txt", workspace: ws).path, "/abs/file.txt")
        expectEqual(Util.resolvePath("sub/file.txt", workspace: ws).path, "/tmp/project/sub/file.txt")
        expectEqual(
            Util.resolvePath("~/x.txt", workspace: ws).path,
            ("~/x.txt" as NSString).expandingTildeInPath
        )
    }

    await test("truncateForModel") {
        expectEqual(Util.truncateForModel("abc", maxChars: 10), "abc")
        let truncated = Util.truncateForModel(String(repeating: "x", count: 100), maxChars: 10)
        expect(truncated.hasPrefix("xxxxxxxxxx"))
        expect(truncated.contains("truncated 90 of 100"))
    }

    await test("ToolSessionState read tracking + todos") {
        let s = ToolSessionState()
        expect(!s.wasRead("/tmp/a"))
        s.markRead("/tmp/a")
        expect(s.wasRead("/tmp/a"))
        s.todos = [TodoItem(id: "1", text: "do it", status: .pending)]
        expectEqual(s.todos.count, 1)
    }

    await test("allowKey derivation") {
        expectEqual(AppState.allowKey(toolName: "edit_file", input: [:]), "edit_file")
        expectEqual(
            AppState.allowKey(toolName: "bash", input: ["command": "npm test --silent"]),
            "bash:npm"
        )
    }
}

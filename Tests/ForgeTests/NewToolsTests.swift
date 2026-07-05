import Foundation
@testable import ForgeKit

// MARK: - Fixture

private func withTempWorkspace(_ body: (URL, ToolContext) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("forge-newtools-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let context = ToolContext(workspaceRoot: dir, session: ToolSessionState())
    try await body(dir, context)
}

private func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

// MARK: - Suite

func newToolsTests() async {

    // ---- create_docx

    await test("create_docx: writes a non-empty .docx file") { try await withTempWorkspace { dir, ctx in
        let out = await DocxTool().execute(input: [
            "path": "report.docx",
            "title": "Report",
            "paragraphs": ["# Title", "## Section", "- bullet one", "plain text"],
        ], context: ctx)
        expect(!out.isError, out.content)
        let url = dir.appendingPathComponent("report.docx")
        expect(FileManager.default.fileExists(atPath: url.path))
        expect(fileSize(url) > 0)
    }}

    // ---- create_pptx

    await test("create_pptx: writes a non-empty .pptx file") { try await withTempWorkspace { dir, ctx in
        let out = await PptxTool().execute(input: [
            "path": "deck.pptx",
            "slides": [
                ["title": "Slide 1", "bullets": ["a", "b"]],
                ["title": "Slide 2", "bullets": []],
            ],
        ], context: ctx)
        expect(!out.isError, out.content)
        let url = dir.appendingPathComponent("deck.pptx")
        expect(FileManager.default.fileExists(atPath: url.path))
        expect(fileSize(url) > 0)
    }}

    // ---- create_xlsx

    await test("create_xlsx: writes a non-empty .xlsx file") { try await withTempWorkspace { dir, ctx in
        let out = await XlsxTool().execute(input: [
            "path": "data.xlsx",
            "sheetName": "Data",
            "rows": [
                ["Name", "Score"],
                ["Alice", "42"],
                ["Bob", "7"],
            ],
        ], context: ctx)
        expect(!out.isError, out.content)
        let url = dir.appendingPathComponent("data.xlsx")
        expect(FileManager.default.fileExists(atPath: url.path))
        expect(fileSize(url) > 0)
    }}

    // ---- web_search

    await test("web_search: returns without crashing") { try await withTempWorkspace { _, ctx in
        let out = await WebSearchTool().execute(input: ["query": "swift programming language"], context: ctx)
        // No live-network guarantee in CI: accept either a successful non-empty
        // result or a graceful network-error ToolOutput, just don't crash.
        if out.isError {
            expect(!out.content.isEmpty)
        } else {
            expect(!out.content.isEmpty)
        }
    }}

    // ---- create_artifact

    await test("create_artifact: generates an id when omitted") { try await withTempWorkspace { _, ctx in
        let out = await ArtifactTool().execute(input: [
            "title": "Hello",
            "kind": "code",
            "language": "swift",
            "content": "print(\"hi\")",
        ], context: ctx)
        expect(!out.isError, out.content)
        expect(out.content.contains("Created artifact: Hello"))
        if case .artifact(let id, let title, let kind, let language, let content)? = out.displayHint {
            expect(!id.isEmpty)
            expectEqual(title, "Hello")
            expectEqual(kind, "code")
            expectEqual(language, "swift")
            expectEqual(content, "print(\"hi\")")
        } else {
            fail("expected artifact hint")
        }
    }}

    await test("create_artifact: round-trips a provided id as an update") { try await withTempWorkspace { _, ctx in
        let out = await ArtifactTool().execute(input: [
            "id": "existing-id",
            "title": "Updated Doc",
            "kind": "markdown",
            "content": "# Hi",
        ], context: ctx)
        expect(!out.isError, out.content)
        expect(out.content.contains("Updated artifact: Updated Doc"))
        if case .artifact(let id, _, _, let language, _)? = out.displayHint {
            expectEqual(id, "existing-id")
            expect(language == nil)
        } else {
            fail("expected artifact hint")
        }
    }}

    await test("create_artifact: missing required fields errors") { try await withTempWorkspace { _, ctx in
        let missingTitle = await ArtifactTool().execute(input: ["kind": "code", "content": "x"], context: ctx)
        expect(missingTitle.isError)
        let missingKind = await ArtifactTool().execute(input: ["title": "T", "content": "x"], context: ctx)
        expect(missingKind.isError)
        let missingContent = await ArtifactTool().execute(input: ["title": "T", "kind": "code"], context: ctx)
        expect(missingContent.isError)
    }}
}

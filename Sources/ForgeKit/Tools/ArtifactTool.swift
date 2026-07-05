import Foundation

struct ArtifactTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "create_artifact",
            description: "Create or update a named artifact (code, a document, an SVG, a small HTML page, or a Mermaid diagram) shown in a dedicated panel instead of only inline in the chat. Omit `id` to create a new artifact; pass an existing artifact's `id` to update it in place.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "title": ["type": "string"],
                    "kind": ["type": "string", "enum": ["code", "markdown", "html", "svg", "mermaid"]],
                    "language": ["type": "string"],
                    "content": ["type": "string"],
                ],
                "required": ["title", "kind", "content"],
            ]
        )
    }

    var permissionClass: PermissionClass { .read }   // auto-approved: pure UI signal, no side effects

    func summarize(input: JSONValue) -> String {
        input["title"]?.stringValue ?? "untitled artifact"
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let title = input["title"]?.stringValue, !title.isEmpty else {
            return .error("create_artifact: missing required parameter `title`.")
        }
        guard let kind = input["kind"]?.stringValue, !kind.isEmpty else {
            return .error("create_artifact: missing required parameter `kind`.")
        }
        guard let content = input["content"]?.stringValue else {
            return .error("create_artifact: missing required parameter `content`.")
        }
        let language = input["language"]?.stringValue
        let providedId = input["id"]?.stringValue
        let id = providedId ?? UUID().uuidString

        return ToolOutput(
            content: providedId != nil ? "Updated artifact: \(title)" : "Created artifact: \(title)",
            displayHint: .artifact(id: id, title: title, kind: kind, language: language, content: content)
        )
    }
}

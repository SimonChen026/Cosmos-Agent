import Foundation

struct TodoTool: AgentTool {
    var spec: ToolSpec {
        ToolSpec(
            name: "todo_write",
            description: "Replace your task plan shown to the user. Use for multi-step tasks: send the full list every time, updating statuses as you go. Statuses: pending, inProgress, completed.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "items": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id": ["type": "string"],
                                "text": ["type": "string"],
                                "status": ["type": "string", "enum": ["pending", "inProgress", "completed"]],
                            ],
                            "required": ["text"],
                        ],
                    ],
                ],
                "required": ["items"],
            ]
        )
    }

    var permissionClass: PermissionClass { .read }   // auto-approved

    func summarize(input: JSONValue) -> String {
        let n = input["items"]?.arrayValue?.count ?? 0
        return "update plan (\(n) item\(n == 1 ? "" : "s"))"
    }

    func execute(input: JSONValue, context: ToolContext) async -> ToolOutput {
        guard let array = input["items"]?.arrayValue else {
            return .error("todo_write: missing required parameter `items` (array).")
        }
        var items: [TodoItem] = []
        for (i, value) in array.enumerated() {
            guard let text = value["text"]?.stringValue, !text.isEmpty else {
                return .error("todo_write: items[\(i)] is missing `text`.")
            }
            let id = value["id"]?.stringValue ?? String(i + 1)
            let status = value["status"]?.stringValue
                .flatMap(TodoStatus.init(rawValue:)) ?? .pending
            items.append(TodoItem(id: id, text: text, status: status))
        }
        context.session.todos = items
        return ToolOutput(
            content: "Todo list updated (\(items.count) item\(items.count == 1 ? "" : "s"))",
            displayHint: .todoList(items: items)
        )
    }
}

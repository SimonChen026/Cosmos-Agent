import Foundation

func makeDefaultTools() -> [any AgentTool] {
    makeSubagentTools() + [AgentSpawnTool()]
}

/// Everything except the spawn tool — subagents cannot spawn subagents.
func makeSubagentTools() -> [any AgentTool] {
    [
        ReadTool(),
        WriteTool(),
        EditTool(),
        ListDirTool(),
        GlobTool(),
        GrepTool(),
        BashTool(),
        TodoTool(),
    ]
}

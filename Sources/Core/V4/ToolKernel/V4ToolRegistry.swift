import Foundation

struct V4ToolRegistry: V4ToolKernelRegistry {
    private let toolsByName: [String: any V4Tool]

    init(tools: [any V4Tool]) {
        var mapping = [String: any V4Tool]()
        for tool in tools {
            mapping[tool.spec.toolName] = tool
        }
        self.toolsByName = mapping
    }

    func spec(for toolName: String) -> V4ToolSpec? {
        toolsByName[toolName]?.spec
    }

    func tool(for toolName: String) -> (any V4Tool)? {
        toolsByName[toolName]
    }

    func allSpecs() -> [V4ToolSpec] {
        toolsByName.values.map(\.spec).sorted { $0.toolName < $1.toolName }
    }

    static func live(
        modelSlotManager: V4ModelSlotManager? = nil,
        generationProvider: (any TextGenerationProvider)? = nil,
        shellAllowlist: Set<String> = V4ShellCommandTool.defaultAllowlist
    ) -> V4ToolRegistry {
        V4ToolRegistry(
            tools: [
                V4TextTransformTool(
                    modelSlotManager: modelSlotManager,
                    generationProvider: generationProvider ?? OpenAITextGenerationProvider()
                ),
                V4ShellCommandTool(allowlist: shellAllowlist),
                V4AppleNotesTool()
            ]
        )
    }
}

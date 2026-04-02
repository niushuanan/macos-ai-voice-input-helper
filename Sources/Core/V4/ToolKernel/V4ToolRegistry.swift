import Foundation

struct V4ToolRegistry: V4ToolKernelRegistry {
    private let toolsByName: [String: any V4Tool]
    private let manifestIndex: V4ToolManifestIndex

    init(
        tools: [any V4Tool],
        manifests: [V4ToolManifest]? = nil
    ) {
        var mapping = [String: any V4Tool]()
        for tool in tools {
            mapping[tool.spec.toolName] = tool
        }
        self.toolsByName = mapping
        self.manifestIndex = V4ToolManifestIndex(
            manifests: manifests ?? tools.map {
                V4ToolManifest.derived(from: $0.spec)
            }
        )
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

    func manifest(for toolName: String) -> V4ToolManifest? {
        manifestIndex.manifest(for: toolName)
    }

    func search(keyword: String) -> [V4ToolManifest] {
        manifestIndex.search(keyword: keyword)
    }

    func list(by scope: MagicianPermissionScope?) -> [V4ToolManifest] {
        manifestIndex.list(by: scope)
    }

    static func live(
        modelSlotManager: V4ModelSlotManager? = nil,
        generationProvider: (any TextGenerationProvider)? = nil,
        shellAllowlist: Set<String> = V4ShellCommandTool.defaultAllowlist,
        timeMachineService: V4TimeMachineService? = nil,
        providerSettingsStore: ProviderSettingsStore? = nil,
        mailAddressBookStore: MailAddressBookStore? = nil,
        cliRegistry: MagicianCLIRegistry = MagicianCLIRegistry()
    ) -> V4ToolRegistry {
        let resolvedGenerationProvider = generationProvider ?? OpenAITextGenerationProvider()
        var tools: [any V4Tool] = [
            V4TextTransformTool(
                modelSlotManager: modelSlotManager,
                generationProvider: resolvedGenerationProvider
            ),
            V4ShellCommandTool(allowlist: shellAllowlist),
            V4AppleScriptTool(),
            V4CalendarCreateTool(),
            V4AppleNotesTool(),
            V4MailComposeTool(
                addressBookStore: mailAddressBookStore,
                providerSettingsStore: providerSettingsStore,
                generationProvider: resolvedGenerationProvider
            ),
            V4MusicControlTool(
                modelSlotManager: modelSlotManager,
                generationProvider: resolvedGenerationProvider
            ),
            V4FeishuCLITool(
                providerSettingsStore: providerSettingsStore,
                cliRegistry: cliRegistry
            )
        ]
        if let timeMachineService {
            tools.append(V4TimeMachineCreateTool(service: timeMachineService))
            tools.append(V4TimeMachineRemindTool(service: timeMachineService))
        }

        return V4ToolRegistry(
            tools: tools,
            manifests: liveManifests(for: tools)
        )
    }

    private static func liveManifests(for tools: [any V4Tool]) -> [V4ToolManifest] {
        let manifestsByID = Dictionary(
            uniqueKeysWithValues: tools.map { tool in
                (tool.spec.toolID, manifest(for: tool.spec))
            }
        )
        return tools.compactMap { manifestsByID[$0.spec.toolID] }
    }

    private static func manifest(for spec: V4ToolSpec) -> V4ToolManifest {
        switch spec.toolID {
        case "text.transform":
            return .derived(
                from: spec,
                domain: "text",
                retryPolicy: .transientSingleRetry,
                evidenceRequirement: .summary,
                keywords: ["text", "改写", "翻译", "polish", "transform"]
            )
        case "shell.command.run":
            return .derived(
                from: spec,
                domain: "shell",
                retryPolicy: .none,
                evidenceRequirement: .structured(requiredKeys: ["command", "exitCode"]),
                keywords: ["shell.command.run", "命令", "终端", "shell"]
            )
        case "applescript.run":
            return .derived(
                from: spec,
                domain: "automation",
                retryPolicy: .transientSingleRetry,
                evidenceRequirement: .structured(requiredKeys: ["stdout", "exitCode"]),
                keywords: ["applescript.run", "AppleScript", "自动化"]
            )
        case "apple.calendar.create":
            return .derived(
                from: spec,
                domain: "calendar",
                retryPolicy: .transientSingleRetry,
                evidenceRequirement: .structured(requiredKeys: ["eventID", "startAt", "endAt"]),
                keywords: ["calendar.create_event", "日程", "会议", "Calendar"]
            )
        case "apple.notes.create":
            return .derived(
                from: spec,
                domain: "notes",
                retryPolicy: .transientSingleRetry,
                evidenceRequirement: .structured(requiredKeys: ["noteID"]),
                keywords: ["notes.create_note", "备忘录", "Notes"]
            )
        case "apple.mail.compose":
            return .derived(
                from: spec,
                domain: "mail",
                retryPolicy: .transientSingleRetry,
                evidenceRequirement: .structured(requiredKeys: ["mailStatus"]),
                keywords: ["mail.compose_or_send", "邮件", "Mail", "发邮件"]
            )
        case "apple.music.control":
            return .derived(
                from: spec,
                domain: "music",
                retryPolicy: .transientSingleRetry,
                evidenceRequirement: .structured(requiredKeys: ["action", "state"]),
                keywords: ["music.control", "音乐", "Music", "播放", "暂停"]
            )
        case "feishu.cli":
            return .derived(
                from: spec,
                domain: "feishu",
                retryPolicy: .transientDoubleRetry,
                evidenceRequirement: .structured(requiredKeys: ["operation", "evidenceID"]),
                keywords: ["feishu.cli", "飞书", "lark", "calendar", "docs", "message"]
            )
        case "time_machine.create":
            return .derived(
                from: spec,
                domain: "time_machine",
                retryPolicy: .none,
                evidenceRequirement: .structured(requiredKeys: ["itemID"]),
                keywords: ["time_machine.create", "时光机", "记录"]
            )
        case "time_machine.remind":
            return .derived(
                from: spec,
                domain: "time_machine",
                retryPolicy: .none,
                evidenceRequirement: .structured(requiredKeys: ["itemID"]),
                keywords: ["time_machine.remind", "提醒", "时光机"]
            )
        default:
            return .derived(from: spec)
        }
    }
}

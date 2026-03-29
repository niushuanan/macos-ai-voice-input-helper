import Foundation

struct FeishuCLIBackendDescriptor: Equatable {
    enum Kind: Equatable {
        case feishu
        case larkCLI
    }

    let kind: Kind
    let executablePath: String
    let commandName: String
}

struct FeishuCLIAvailability: Equatable {
    let backend: FeishuCLIBackendDescriptor?

    var isAvailable: Bool {
        backend != nil
    }

    var commandName: String? {
        backend?.commandName
    }

    static let unavailable = FeishuCLIAvailability(backend: nil)
}

enum FeishuCLIRiskLevel: String {
    case read
    case write
    case highRiskWrite

    var displayText: String {
        switch self {
        case .read:
            return "只读"
        case .write:
            return "写入"
        case .highRiskWrite:
            return "高风险写入"
        }
    }
}

enum FeishuCanonicalOperation: String, CaseIterable, Codable {
    case bitableApp = "feishu_bitable_app"
    case bitableAppTable = "feishu_bitable_app_table"
    case bitableAppTableField = "feishu_bitable_app_table_field"
    case bitableAppTableRecord = "feishu_bitable_app_table_record"
    case bitableAppTableView = "feishu_bitable_app_table_view"
    case calendarCalendar = "feishu_calendar_calendar"
    case calendarEvent = "feishu_calendar_event"
    case calendarEventAttendee = "feishu_calendar_event_attendee"
    case calendarFreebusy = "feishu_calendar_freebusy"
    case chat = "feishu_chat"
    case chatMembers = "feishu_chat_members"
    case createDoc = "feishu_create_doc"
    case docComments = "feishu_doc_comments"
    case docMedia = "feishu_doc_media"
    case driveFile = "feishu_drive_file"
    case fetchDoc = "feishu_fetch_doc"
    case getUser = "feishu_get_user"
    case imBotImage = "feishu_im_bot_image"
    case imUserFetchResource = "feishu_im_user_fetch_resource"
    case imUserGetMessages = "feishu_im_user_get_messages"
    case imUserGetThreadMessages = "feishu_im_user_get_thread_messages"
    case imUserMessage = "feishu_im_user_message"
    case imUserSearchMessages = "feishu_im_user_search_messages"
    case oauth = "feishu_oauth"
    case oauthBatchAuth = "feishu_oauth_batch_auth"
    case searchDocWiki = "feishu_search_doc_wiki"
    case searchUser = "feishu_search_user"
    case sheet = "feishu_sheet"
    case taskComment = "feishu_task_comment"
    case taskSubtask = "feishu_task_subtask"
    case taskTask = "feishu_task_task"
    case taskTasklist = "feishu_task_tasklist"
    case updateDoc = "feishu_update_doc"
    case wikiSpace = "feishu_wiki_space"
    case wikiSpaceNode = "feishu_wiki_space_node"

    var title: String {
        switch self {
        case .bitableApp:
            return "多维表格 App"
        case .bitableAppTable:
            return "多维表格 Table"
        case .bitableAppTableField:
            return "多维表格字段"
        case .bitableAppTableRecord:
            return "多维表格记录"
        case .bitableAppTableView:
            return "多维表格视图"
        case .calendarCalendar:
            return "日历"
        case .calendarEvent:
            return "日程事件"
        case .calendarEventAttendee:
            return "参会人"
        case .calendarFreebusy:
            return "忙闲查询"
        case .chat:
            return "群聊"
        case .chatMembers:
            return "群成员"
        case .createDoc:
            return "创建文档"
        case .docComments:
            return "文档评论"
        case .docMedia:
            return "文档媒体"
        case .driveFile:
            return "云盘文件"
        case .fetchDoc:
            return "读取文档"
        case .getUser:
            return "用户信息"
        case .imBotImage:
            return "机器人图片消息"
        case .imUserFetchResource:
            return "消息资源读取"
        case .imUserGetMessages:
            return "消息列表"
        case .imUserGetThreadMessages:
            return "线程消息"
        case .imUserMessage:
            return "发送消息"
        case .imUserSearchMessages:
            return "搜索消息"
        case .oauth:
            return "OAuth"
        case .oauthBatchAuth:
            return "批量授权"
        case .searchDocWiki:
            return "搜索文档/Wiki"
        case .searchUser:
            return "搜索用户"
        case .sheet:
            return "电子表格"
        case .taskComment:
            return "任务评论"
        case .taskSubtask:
            return "子任务"
        case .taskTask:
            return "任务"
        case .taskTasklist:
            return "任务列表"
        case .updateDoc:
            return "更新文档"
        case .wikiSpace:
            return "Wiki 空间"
        case .wikiSpaceNode:
            return "Wiki 节点"
        }
    }

    var groupTitle: String {
        switch self {
        case .bitableApp, .bitableAppTable, .bitableAppTableField, .bitableAppTableRecord, .bitableAppTableView:
            return "多维表格"
        case .calendarCalendar, .calendarEvent, .calendarEventAttendee, .calendarFreebusy:
            return "日历"
        case .chat, .chatMembers, .imBotImage, .imUserFetchResource, .imUserGetMessages, .imUserGetThreadMessages, .imUserMessage, .imUserSearchMessages:
            return "IM"
        case .createDoc, .docComments, .docMedia, .fetchDoc, .updateDoc, .searchDocWiki, .wikiSpace, .wikiSpaceNode:
            return "文档与 Wiki"
        case .driveFile:
            return "云盘"
        case .getUser, .searchUser:
            return "用户"
        case .oauth, .oauthBatchAuth:
            return "鉴权"
        case .sheet:
            return "电子表格"
        case .taskComment, .taskSubtask, .taskTask, .taskTasklist:
            return "任务"
        }
    }

    var riskLevel: FeishuCLIRiskLevel {
        switch self {
        case .calendarEvent, .calendarEventAttendee,
             .createDoc, .docComments, .docMedia, .driveFile,
             .imBotImage, .imUserMessage,
             .sheet, .taskComment, .taskSubtask, .taskTask, .taskTasklist,
             .updateDoc:
            return .write
        case .oauth, .oauthBatchAuth:
            return .highRiskWrite
        default:
            return .read
        }
    }

    static func infer(from command: String) -> FeishuCanonicalOperation? {
        let normalized = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else {
            return nil
        }

        for operation in Self.allCases where normalized.contains(operation.rawValue.lowercased()) {
            return operation
        }

        if matchesPattern(
            normalized,
            pattern: #"(添加|新增|创建|安排|加一个|设定).*(日程|行程|会议|课程|上课)"#
        ) {
            return .calendarEvent
        }

        if matchesPattern(
            normalized,
            pattern: #"(今天|明天|后天|上午|下午|晚上|周[一二三四五六日天]|\d+点|:\d{2}).*(日程|行程|会议|课程|上课)"#
        ) {
            return .calendarEvent
        }

        let rules: [(FeishuCanonicalOperation, [String])] = [
            (.oauthBatchAuth, ["批量授权", "batch auth"]),
            (.oauth, ["oauth", "授权", "登录飞书", "飞书登录", "auth"]),
            (.calendarFreebusy, ["忙闲", "freebusy", "空闲"]),
            (.calendarEventAttendee, ["参会", "attendee", "邀请"]),
            (.calendarEvent, ["日程", "议程", "会议", "行程", "课程", "上课", "calendar event", "agenda", "添加日程", "新建日程", "安排日程"]),
            (.calendarCalendar, ["日历", "calendar"]),
            (.createDoc, ["创建文档", "新建文档", "create doc"]),
            (.updateDoc, ["更新文档", "改文档", "update doc"]),
            (.fetchDoc, ["读取文档", "打开文档", "fetch doc"]),
            (.docComments, ["评论", "comment"]),
            (.docMedia, ["文档图片", "文档附件", "media"]),
            (.searchDocWiki, ["搜文档", "搜 wiki", "search wiki", "search doc"]),
            (.wikiSpaceNode, ["wiki 节点", "space node"]),
            (.wikiSpace, ["wiki 空间", "wiki space"]),
            (.driveFile, ["云盘", "drive file", "上传文件", "下载文件"]),
            (.searchUser, ["搜人", "search user", "查人"]),
            (.getUser, ["用户信息", "get user", "我的信息"]),
            (.chatMembers, ["群成员", "chat members"]),
            (.chat, ["群聊", "chat"]),
            (.imUserGetThreadMessages, ["线程消息", "thread messages"]),
            (.imUserSearchMessages, ["搜索消息", "search messages"]),
            (.imUserGetMessages, ["消息列表", "get messages"]),
            (.imUserFetchResource, ["下载消息资源", "fetch resource"]),
            (.imUserMessage, ["发消息", "发送消息", "message send"]),
            (.imBotImage, ["发图片", "bot image"]),
            (.sheet, ["表格", "sheet", "spreadsheet"]),
            (.taskTasklist, ["任务列表", "tasklist"]),
            (.taskSubtask, ["子任务", "subtask"]),
            (.taskComment, ["任务评论", "task comment"]),
            (.taskTask, ["任务", "task"]),
            (.bitableAppTableField, ["字段", "table field"]),
            (.bitableAppTableRecord, ["记录", "table record"]),
            (.bitableAppTableView, ["视图", "table view"]),
            (.bitableAppTable, ["数据表", "table list"]),
            (.bitableApp, ["多维表格", "bitable", "base app"])
        ]

        for (operation, keywords) in rules {
            if keywords.contains(where: { normalized.contains($0.lowercased()) }) {
                return operation
            }
        }

        return nil
    }

    private static func matchesPattern(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}

struct FeishuCLICommandPlan: Equatable {
    enum ExecutionMode: Equatable {
        case execute
        case needsMoreDetail
    }

    let executablePath: String
    let arguments: [String]
    let summary: String
    let riskLevel: FeishuCLIRiskLevel
    let executionMode: ExecutionMode
}

final class FeishuCLIProvider {
    private static let safeArgumentCharacterSet: CharacterSet = {
        let controls = CharacterSet.controlCharacters
        return controls
    }()

    private static let maxArgumentLength = 240
    private static let maxOutputCharacters = 16_000
    private static let timeoutSeconds: TimeInterval = 16

    static func detectAvailability(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableOverride: String? = nil,
        additionalSearchDirectories: [String] = []
    ) -> FeishuCLIAvailability {
        if
            let overrideExecutable = resolveOverrideExecutable(
                executableOverride,
                fileManager: fileManager
            ),
            let descriptor = backendDescriptor(for: overrideExecutable)
        {
            return FeishuCLIAvailability(backend: descriptor)
        }

        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let fallbackDirectories = defaultSearchDirectories(environment: environment)
        let mergedDirectories = mergedSearchDirectories(
            pathDirectories: pathDirectories,
            fallbackDirectories: fallbackDirectories,
            additionalDirectories: additionalSearchDirectories
        )

        if
            let resolved = resolveExecutable(
                named: "lark-cli",
                fileManager: fileManager,
                directories: mergedDirectories
            )
        {
            return FeishuCLIAvailability(
                backend: FeishuCLIBackendDescriptor(
                    kind: .larkCLI,
                    executablePath: resolved,
                    commandName: "lark-cli"
                )
            )
        }

        if
            let resolved = resolveExecutable(
                named: "feishu",
                fileManager: fileManager,
                directories: mergedDirectories
            )
        {
            return FeishuCLIAvailability(
                backend: FeishuCLIBackendDescriptor(
                    kind: .feishu,
                    executablePath: resolved,
                    commandName: "feishu"
                )
            )
        }

        return .unavailable
    }

    static func buildProcessEnvironment(
        executablePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var resolvedEnvironment = environment
        let executableDirectory = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .path

        let currentPathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let fallbackDirectories = defaultSearchDirectories(environment: environment)
        let mergedPathEntries = mergedSearchDirectories(
            pathDirectories: currentPathEntries + [executableDirectory],
            fallbackDirectories: fallbackDirectories,
            additionalDirectories: []
        )
        resolvedEnvironment["PATH"] = mergedPathEntries.joined(separator: ":")

        if (resolvedEnvironment["HOME"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedEnvironment["HOME"] = NSHomeDirectory()
        }
        return resolvedEnvironment
    }

    func execute(
        operation: FeishuCanonicalOperation,
        spokenCommand: String,
        explicitArguments: [String],
        availability: FeishuCLIAvailability
    ) async -> Result<MagicianExecutionResult, MagicianError> {
        guard let backend = availability.backend else {
            return .failure(
                MagicianError(
                    code: .cliUnavailable,
                    userMessage: "未找到飞书 CLI，请先安装并配置。",
                    debugMessage: "feishu cli unavailable",
                    recoverAction: "open_feishu_cli_docs"
                )
            )
        }

        guard isExecutableAllowed(backend.executablePath) else {
            return .failure(
                MagicianError(
                    code: .cliCommandRejected,
                    userMessage: "CLI 可执行路径不在允许范围内。",
                    debugMessage: "executable rejected: \(backend.executablePath)",
                    recoverAction: nil
                )
            )
        }

        var plan = makeCommandPlan(
            operation: operation,
            spokenCommand: spokenCommand,
            explicitArguments: explicitArguments,
            backend: backend
        )

        if
            backend.kind == .larkCLI,
            operation == .imUserMessage,
            plan.executionMode == .needsMoreDetail,
            explicitArguments.isEmpty,
            let autoPlan = await autoResolvedIMMessagePlan(
                spokenCommand: spokenCommand,
                backend: backend,
                fallbackPlan: plan
            )
        {
            plan = autoPlan
        }

        guard argumentsAreSafe(plan.arguments) else {
            return .failure(
                MagicianError(
                    code: .cliCommandRejected,
                    userMessage: "命令参数不符合安全规则，请换个说法再试。",
                    debugMessage: "unsafe cli args for \(operation.rawValue)",
                    recoverAction: "retry_command"
                )
            )
        }

        let processResult = await runProcessWithTimeout(
            executablePath: plan.executablePath,
            arguments: plan.arguments,
            timeoutSeconds: Self.timeoutSeconds,
            maxOutputCharacters: Self.maxOutputCharacters,
            environment: Self.buildProcessEnvironment(executablePath: plan.executablePath)
        )

        let output = mergedOutput(from: processResult)
        if processResult.exitCode == 0 {
            if plan.executionMode == .needsMoreDetail {
                return .failure(
                    MagicianError(
                        code: .intentParseFailed,
                        userMessage: missingArgumentMessage(for: operation),
                        debugMessage: output,
                        recoverAction: "retry_command"
                    )
                )
            }

            if let envelope = parsedCLIEnvelope(from: output) {
                if envelope.ok == false {
                    return .failure(
                        MagicianError(
                            code: .toolExecutionFailed,
                            userMessage: userFacingCLIErrorMessage(
                                envelope.errorMessage ?? "飞书返回失败",
                                operation: operation
                            ),
                            debugMessage: output,
                            recoverAction: "retry_command"
                        )
                    )
                }

                if isCalendarCreateArguments(plan.arguments), envelope.eventID == nil {
                    return .failure(
                        MagicianError(
                            code: .toolExecutionFailed,
                            userMessage: "飞书没有返回有效的日程 ID，创建结果不可靠，请重试。",
                            debugMessage: output,
                            recoverAction: "retry_command"
                        )
                    )
                }
            }

            let display = output.isEmpty ? plan.summary : output
            return .success(
                MagicianExecutionResult(
                    intent: .feishuCLI,
                    userMessage: "飞书 CLI 执行成功：\(plan.summary)",
                    outputText: output.isEmpty ? nil : output,
                    historyDisplayText: "飞书 CLI：\(display)",
                    fallbackUsed: false
                )
            )
        }

        if
            let envelope = parsedCLIEnvelope(from: output),
            let errorMessage = envelope.errorMessage,
            !errorMessage.isEmpty
        {
            return .failure(
                MagicianError(
                    code: .toolExecutionFailed,
                    userMessage: userFacingCLIErrorMessage(errorMessage, operation: operation),
                    debugMessage: output,
                    recoverAction: "retry_command"
                )
            )
        }

        if isLikelyAuthError(processResult.detail) {
            return .failure(
                MagicianError(
                    code: .cliAuthRequired,
                    userMessage: "飞书 CLI 鉴权状态异常，请先完成登录后再试。",
                    debugMessage: processResult.detail,
                    recoverAction: "open_feishu_auth"
                )
            )
        }

        if processResult.exitCode == -998 {
            return .failure(
                MagicianError(
                    code: .cliExecutionTimedOut,
                    userMessage: "飞书 CLI 执行超时，请简化指令后再试。",
                    debugMessage: processResult.detail,
                    recoverAction: "retry_command"
                )
            )
        }

        return .failure(
            MagicianError(
                code: .toolExecutionFailed,
                userMessage: "飞书 CLI 执行失败，请检查命令参数或登录状态。",
                debugMessage: processResult.detail,
                recoverAction: "retry_command"
            )
        )
    }

    func groupedCatalog() -> [(group: String, operations: [FeishuCanonicalOperation])] {
        let groups = Dictionary(grouping: FeishuCanonicalOperation.allCases, by: { $0.groupTitle })
        return groups
            .map { key, value in
                (group: key, operations: value.sorted(by: { $0.rawValue < $1.rawValue }))
            }
            .sorted(by: { $0.group < $1.group })
    }

    private func makeCommandPlan(
        operation: FeishuCanonicalOperation,
        spokenCommand: String,
        explicitArguments: [String],
        backend: FeishuCLIBackendDescriptor
    ) -> FeishuCLICommandPlan {
        switch backend.kind {
        case .larkCLI:
            let args = larkCLIArguments(
                operation: operation,
                spokenCommand: spokenCommand,
                explicitArguments: explicitArguments
            )
            return FeishuCLICommandPlan(
                executablePath: backend.executablePath,
                arguments: args,
                summary: "\(operation.title)（\(backend.commandName)）",
                riskLevel: operation.riskLevel,
                executionMode: executionMode(
                    operation: operation,
                    spokenCommand: spokenCommand,
                    arguments: args,
                    explicitArguments: explicitArguments
                )
            )
        case .feishu:
            let args = feishuArguments(
                operation: operation,
                spokenCommand: spokenCommand,
                explicitArguments: explicitArguments
            )
            return FeishuCLICommandPlan(
                executablePath: backend.executablePath,
                arguments: args,
                summary: "\(operation.title)（\(backend.commandName)）",
                riskLevel: operation.riskLevel,
                executionMode: .execute
            )
        }
    }

    private func larkCLIArguments(
        operation: FeishuCanonicalOperation,
        spokenCommand: String,
        explicitArguments: [String]
    ) -> [String] {
        let normalizedExplicitArguments = sanitizedExplicitArguments(explicitArguments)
        let hasExplicitArguments = !normalizedExplicitArguments.isEmpty
        let queryHint = inferredQuery(from: spokenCommand)

        var args: [String]

        switch operation {
        case .bitableApp:
            args = hasExplicitArguments ? ["base", "+base-get"] : ["base", "+base-get", "--help"]
        case .bitableAppTable:
            args = hasExplicitArguments ? ["base", "+table-list"] : ["base", "+table-list", "--help"]
        case .bitableAppTableField:
            args = hasExplicitArguments ? ["base", "+field-list"] : ["base", "+field-list", "--help"]
        case .bitableAppTableRecord:
            if containsAny(spokenCommand, keywords: ["写入", "更新", "修改", "新增", "create", "update"]) {
                args = hasExplicitArguments ? ["base", "+record-upsert"] : ["base", "+record-upsert", "--help"]
            } else {
                args = hasExplicitArguments ? ["base", "+record-list"] : ["base", "+record-list", "--help"]
            }
        case .bitableAppTableView:
            args = hasExplicitArguments ? ["base", "+view-list"] : ["base", "+view-list", "--help"]
        case .calendarCalendar:
            args = inferredAgendaArguments(from: spokenCommand) ?? ["calendar", "+agenda"]
        case .calendarEvent:
            if isCalendarCreateCommand(spokenCommand) {
                if hasExplicitArguments {
                    args = ["calendar", "+create"]
                } else if let inferredCreateArgs = inferredCalendarCreateArguments(from: spokenCommand) {
                    args = inferredCreateArgs
                } else {
                    args = ["calendar", "+create", "--help"]
                }
            } else {
                args = inferredAgendaArguments(from: spokenCommand) ?? ["calendar", "+agenda"]
            }
        case .calendarEventAttendee:
            args = hasExplicitArguments ? ["calendar", "+create"] : ["calendar", "+create", "--help"]
        case .calendarFreebusy:
            if hasExplicitArguments {
                args = ["calendar", "+freebusy"]
            } else if let inferredRange = inferredTimeRange(from: spokenCommand) {
                args = [
                    "calendar",
                    "+freebusy",
                    "--start",
                    iso8601LocalString(from: inferredRange.start),
                    "--end",
                    iso8601LocalString(from: inferredRange.end)
                ]
            } else {
                args = ["calendar", "+freebusy", "--help"]
            }
        case .chat:
            if let queryHint {
                args = ["im", "+chat-search", "--query", queryHint]
            } else {
                args = hasExplicitArguments ? ["im", "+chat-search"] : ["im", "+chat-search", "--help"]
            }
        case .chatMembers:
            if let queryHint {
                args = ["im", "+chat-search", "--query", queryHint]
            } else {
                args = hasExplicitArguments ? ["im", "+chat-search"] : ["im", "+chat-search", "--help"]
            }
        case .createDoc:
            args = hasExplicitArguments ? ["docs", "+create"] : ["docs", "+create", "--help"]
        case .docComments:
            args = hasExplicitArguments ? ["drive", "+add-comment"] : ["drive", "+add-comment", "--help"]
        case .docMedia:
            if containsAny(spokenCommand, keywords: ["下载", "download"]) {
                args = hasExplicitArguments ? ["docs", "+media-download"] : ["docs", "+media-download", "--help"]
            } else {
                args = hasExplicitArguments ? ["docs", "+media-insert"] : ["docs", "+media-insert", "--help"]
            }
        case .driveFile:
            if containsAny(spokenCommand, keywords: ["上传", "upload"]) {
                args = hasExplicitArguments ? ["drive", "+upload"] : ["drive", "+upload", "--help"]
            } else {
                args = hasExplicitArguments ? ["drive", "+download"] : ["drive", "+download", "--help"]
            }
        case .fetchDoc:
            args = hasExplicitArguments ? ["docs", "+fetch"] : ["docs", "+fetch", "--help"]
        case .getUser:
            args = ["contact", "+get-user"]
        case .imBotImage:
            args = hasExplicitArguments
                ? ["im", "+messages-send", "--as", "bot"]
                : ["im", "+messages-send", "--as", "bot", "--help"]
        case .imUserFetchResource:
            args = hasExplicitArguments ? ["im", "+messages-resources-download"] : ["im", "+messages-resources-download", "--help"]
        case .imUserGetMessages:
            args = hasExplicitArguments ? ["im", "+chat-messages-list"] : ["im", "+chat-messages-list", "--help"]
        case .imUserGetThreadMessages:
            args = hasExplicitArguments ? ["im", "+threads-messages-list"] : ["im", "+threads-messages-list", "--help"]
        case .imUserMessage:
            if containsAny(spokenCommand, keywords: ["回复", "reply"]) {
                args = hasExplicitArguments
                    ? ["im", "+messages-reply", "--as", "bot"]
                    : ["im", "+messages-reply", "--as", "bot", "--help"]
            } else {
                if hasExplicitArguments {
                    args = ["im", "+messages-send", "--as", "bot"]
                } else if let inlineSendArgs = inferredInlineIMSendArguments(from: spokenCommand) {
                    args = ["im", "+messages-send", "--as", "bot"] + inlineSendArgs
                } else {
                    args = ["im", "+messages-send", "--as", "bot", "--help"]
                }
            }
        case .imUserSearchMessages:
            if let queryHint {
                args = ["im", "+messages-search", "--query", queryHint]
            } else {
                args = hasExplicitArguments ? ["im", "+messages-search"] : ["im", "+messages-search", "--help"]
            }
        case .oauth:
            args = ["auth", "status"]
        case .oauthBatchAuth:
            args = ["auth", "login", "--recommend", "--no-wait"]
        case .searchDocWiki:
            if let queryHint {
                args = ["docs", "+search", "--query", queryHint]
            } else {
                args = ["docs", "+search"]
            }
        case .searchUser:
            if let queryHint {
                args = ["contact", "+search-user", "--query", queryHint]
            } else {
                args = hasExplicitArguments ? ["contact", "+search-user"] : ["contact", "+search-user", "--help"]
            }
        case .sheet:
            if containsAny(spokenCommand, keywords: ["写", "追加", "append", "write"]) {
                args = hasExplicitArguments ? ["sheets", "+write"] : ["sheets", "+write", "--help"]
            } else if containsAny(spokenCommand, keywords: ["导出", "export"]) {
                args = hasExplicitArguments ? ["sheets", "+export"] : ["sheets", "+export", "--help"]
            } else {
                args = hasExplicitArguments ? ["sheets", "+read"] : ["sheets", "+read", "--help"]
            }
        case .taskComment:
            args = hasExplicitArguments ? ["task", "+comment"] : ["task", "+comment", "--help"]
        case .taskSubtask:
            args = hasExplicitArguments ? ["task", "+create"] : ["task", "+create", "--help"]
        case .taskTask:
            if containsAny(spokenCommand, keywords: ["更新", "update", "完成", "complete"]) {
                args = hasExplicitArguments ? ["task", "+update"] : ["task", "+update", "--help"]
            } else if containsAny(spokenCommand, keywords: ["查", "查看", "list", "search"]) {
                if let queryHint {
                    args = ["task", "+get-my-tasks", "--query", queryHint]
                } else {
                    args = ["task", "+get-my-tasks"]
                }
            } else {
                args = hasExplicitArguments ? ["task", "+create"] : ["task", "+create", "--help"]
            }
        case .taskTasklist:
            args = hasExplicitArguments ? ["task", "+tasklist-create"] : ["task", "+tasklist-create", "--help"]
        case .updateDoc:
            args = hasExplicitArguments ? ["docs", "+update"] : ["docs", "+update", "--help"]
        case .wikiSpace:
            if let queryHint {
                args = ["docs", "+search", "--query", queryHint]
            } else {
                args = ["docs", "+search"]
            }
        case .wikiSpaceNode:
            args = hasExplicitArguments ? ["wiki", "spaces", "get_node"] : ["wiki", "spaces", "get_node", "--help"]
        }

        return args + normalizedExplicitArguments
    }

    private func feishuArguments(
        operation: FeishuCanonicalOperation,
        spokenCommand: String,
        explicitArguments: [String]
    ) -> [String] {
        var args: [String]
        switch operation {
        case .oauth:
            args = ["auth", "status"]
        case .oauthBatchAuth:
            args = ["auth", "help"]
        default:
            if containsAny(spokenCommand, keywords: ["帮助", "help"]) {
                args = ["help"]
            } else {
                args = [operation.rawValue]
            }
        }

        return args + sanitizedExplicitArguments(explicitArguments)
    }

    private func inferredQuery(from spokenCommand: String) -> String? {
        let trimmed = spokenCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let stopWords = [
            "飞书",
            "feishu",
            "lark",
            "查一下",
            "搜一下",
            "搜索",
            "查询",
            "帮我",
            "请",
            "一下",
            "消息",
            "文档",
            "用户",
            "群聊",
            "任务",
            "日程"
        ]
        var reduced = trimmed
        for stopWord in stopWords {
            reduced = reduced.replacingOccurrences(
                of: stopWord,
                with: "",
                options: [.caseInsensitive]
            )
        }
        reduced = reduced
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !reduced.isEmpty else {
            return nil
        }
        return String(reduced.prefix(80))
    }

    private func sanitizedExplicitArguments(_ raw: [String]) -> [String] {
        raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(6)
            .map { String($0) }
    }

    private func argumentsAreSafe(_ arguments: [String]) -> Bool {
        for argument in arguments {
            if argument.count > Self.maxArgumentLength {
                return false
            }
            if argument.rangeOfCharacter(from: Self.safeArgumentCharacterSet) != nil {
                return false
            }
        }
        return true
    }

    private func executionMode(
        operation: FeishuCanonicalOperation,
        spokenCommand: String,
        arguments: [String],
        explicitArguments: [String]
    ) -> FeishuCLICommandPlan.ExecutionMode {
        let hasExplicitArguments = !sanitizedExplicitArguments(explicitArguments).isEmpty
        let askedForHelp = containsAny(
            spokenCommand,
            keywords: ["help", "帮助", "参数", "怎么用", "用法", "--help"]
        )
        if
            usesHelpFallback(arguments),
            !hasExplicitArguments,
            !askedForHelp,
            operation != .oauthBatchAuth
        {
            return .needsMoreDetail
        }
        return .execute
    }

    private func usesHelpFallback(_ arguments: [String]) -> Bool {
        arguments.contains("--help")
    }

    private func missingArgumentMessage(for operation: FeishuCanonicalOperation) -> String {
        switch operation {
        case .createDoc, .updateDoc, .fetchDoc, .docMedia, .docComments:
            return "这条飞书文档命令还缺少必要参数，请补充文档对象或内容后再试。"
        case .imUserMessage, .imBotImage:
            return "发消息需要目标和内容，请补充群聊/用户和消息文本后再试。"
        case .driveFile:
            return "云盘读写需要文件信息，请补充文件 token 或本地路径后再试。"
        case .sheet:
            return "表格操作需要表格地址或 token，请补充后再试。"
        case .taskTask, .taskComment, .taskSubtask, .taskTasklist:
            return "任务操作还缺少目标信息，请补充任务或任务列表后再试。"
        case .bitableApp, .bitableAppTable, .bitableAppTableField, .bitableAppTableRecord, .bitableAppTableView:
            return "多维表格操作需要 base/table 信息，请补充后再试。"
        case .calendarEvent, .calendarEventAttendee, .calendarFreebusy:
            return "日历操作还缺少时间或对象，请补充后再试。"
        case .wikiSpace, .wikiSpaceNode:
            return "Wiki 操作需要空间或节点参数，请补充后再试。"
        default:
            return "这条飞书命令还缺少必要参数，请补充更具体的信息后再试。"
        }
    }

    private struct CalendarTimeRange {
        let start: Date
        let end: Date
    }

    private struct CLIEnvelope {
        let ok: Bool?
        let errorMessage: String?
        let eventID: String?
    }

    private func isCalendarCreateArguments(_ arguments: [String]) -> Bool {
        guard arguments.count >= 2 else {
            return false
        }
        return arguments[0] == "calendar" && arguments[1] == "+create"
    }

    private func parsedCLIEnvelope(from text: String) -> CLIEnvelope? {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }

        let ok = dictionary["ok"] as? Bool
        let errorMessage = (dictionary["error"] as? [String: Any])?["message"] as? String
        let eventID = (dictionary["data"] as? [String: Any])?["event_id"] as? String

        return CLIEnvelope(
            ok: ok,
            errorMessage: errorMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            eventID: eventID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func userFacingCLIErrorMessage(
        _ message: String,
        operation: FeishuCanonicalOperation
    ) -> String {
        let lowered = message.lowercased()
        if lowered.contains("only supports: bot") || lowered.contains("use --as bot") {
            return "这条消息命令只能以 bot 身份执行，请先配置 bot 侧权限。"
        }
        if lowered.contains("bot/user can not be out of the chat") {
            return "机器人当前不在目标群里，请先把 bot 拉进群再发送消息。"
        }
        if lowered.contains("permission denied") || lowered.contains("scope") {
            return "飞书返回权限不足，请检查 app scope 并重新授权。"
        }
        if operation == .calendarEvent, lowered.contains("start") {
            return "日程时间参数不合法，请补充更明确的日期和时间。"
        }
        return "飞书 CLI 返回失败：\(message)"
    }

    private func isCalendarCreateCommand(_ spokenCommand: String) -> Bool {
        containsAny(
            spokenCommand,
            keywords: [
                "创建", "新建", "安排", "建", "添加", "新增", "加入", "加一个", "设定",
                "记录到日程", "记到日程", "create"
            ]
        )
    }

    private func inferredCalendarCreateArguments(from spokenCommand: String) -> [String]? {
        guard let range = inferredTimeRange(from: spokenCommand) else {
            return nil
        }
        let summary = inferredCalendarSummary(from: spokenCommand)
        return [
            "calendar",
            "+create",
            "--summary",
            summary,
            "--start",
            iso8601LocalString(from: range.start),
            "--end",
            iso8601LocalString(from: range.end)
        ]
    }

    private func inferredAgendaArguments(from spokenCommand: String) -> [String]? {
        guard let range = inferredAgendaRange(from: spokenCommand) else {
            return nil
        }
        return [
            "calendar",
            "+agenda",
            "--start",
            iso8601LocalString(from: range.start),
            "--end",
            iso8601LocalString(from: range.end)
        ]
    }

    private func inferredAgendaRange(from spokenCommand: String) -> CalendarTimeRange? {
        let detected = detectedDates(in: spokenCommand)
        let calendar = Calendar.current

        if detected.count >= 2 {
            let start = min(detected[0], detected[1])
            let end = max(detected[0], detected[1])
            return CalendarTimeRange(start: start, end: end)
        }

        let dayReference = detected.first ?? inferredRelativeDayDate(from: spokenCommand)
        guard let dayReference else {
            return nil
        }
        let start = calendar.startOfDay(for: dayReference)
        let end = calendar.date(byAdding: .day, value: 1, to: start)?
            .addingTimeInterval(-1) ?? start.addingTimeInterval(86_399)
        return CalendarTimeRange(start: start, end: end)
    }

    private func inferredTimeRange(from spokenCommand: String) -> CalendarTimeRange? {
        let detected = detectedDates(in: spokenCommand)
        if detected.count >= 2 {
            let start = min(detected[0], detected[1])
            let end = max(detected[0], detected[1])
            if end > start {
                return CalendarTimeRange(start: start, end: end)
            }
        }

        let start = detected.first ?? inferredRelativeDayDate(from: spokenCommand)
        guard let start else {
            return nil
        }
        let fallbackEnd = start.addingTimeInterval(inferredDurationSeconds(from: spokenCommand))
        let end = fallbackEnd > start ? fallbackEnd : start.addingTimeInterval(1_800)
        return CalendarTimeRange(start: start, end: end)
    }

    private func inferredRelativeDayDate(from spokenCommand: String) -> Date? {
        let now = Date()
        let calendar = Calendar.current
        if spokenCommand.contains("今天") {
            return now
        }
        if spokenCommand.contains("明天") {
            return calendar.date(byAdding: .day, value: 1, to: now)
        }
        if spokenCommand.contains("后天") {
            return calendar.date(byAdding: .day, value: 2, to: now)
        }
        return nil
    }

    private func inferredDurationSeconds(from text: String) -> TimeInterval {
        if text.contains("半小时") {
            return 1_800
        }

        if
            let minutesRaw = textMatched(
                in: text,
                pattern: #"([0-9一二两三四五六七八九十]+)\s*(分钟|分|min|mins|minute|minutes)"#
            ),
            let minutes = parsedNumber(from: minutesRaw)
        {
            return max(300, minutes * 60)
        }

        if
            let hoursRaw = textMatched(
                in: text,
                pattern: #"([0-9一二两三四五六七八九十]+)\s*(小时|h|hr|hrs|hour|hours)"#
            ),
            let hours = parsedNumber(from: hoursRaw)
        {
            return max(300, hours * 3_600)
        }

        return 1_800
    }

    private func parsedNumber(from raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(trimmed) {
            return value
        }

        let mapping: [Character: Double] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10
        ]

        if trimmed == "十" {
            return 10
        }
        if trimmed.count == 2, trimmed.first == "十", let second = trimmed.last, let value = mapping[second] {
            return 10 + value
        }
        if trimmed.count == 2, trimmed.last == "十", let first = trimmed.first, let value = mapping[first] {
            return value * 10
        }
        if
            trimmed.count == 3,
            let first = trimmed.first,
            trimmed[trimmed.index(after: trimmed.startIndex)] == "十",
            let last = trimmed.last,
            let tens = mapping[first],
            let ones = mapping[last]
        {
            return tens * 10 + ones
        }

        return mapping[trimmed.first ?? " "] ?? nil
    }

    private func inferredCalendarSummary(from spokenCommand: String) -> String {
        if let quoted = firstQuotedText(in: spokenCommand), let cleaned = cleanedCalendarSummary(quoted) {
            return cleaned
        }

        let patterns = [
            #"(?:添加|新增|加入|安排|创建|新建|设定|记录)(?:一个|一条|个|条)?(.{1,40}?)(?:的)?(?:日程|行程|会议|课程|提醒)"#,
            #"(?:把|将)(.{1,40}?)(?:记录|添加|安排|写入)(?:到|进)?(?:飞书)?(?:日程|日历)"#,
            #"(?:主题是|主题为|关于)\s*(.{1,40})"#
        ]

        for pattern in patterns {
            if let candidate = textMatched(in: spokenCommand, pattern: pattern),
               let cleaned = cleanedCalendarSummary(candidate)
            {
                return cleaned
            }
        }

        if
            let semantic = magicianSemanticPayload(
                from: spokenCommand,
                actionTokens: ["飞书", "日程", "日历", "会议", "行程", "课程", "提醒", "create", "calendar"],
                extraCommandTokens: ["添加", "新增", "安排", "创建", "新建", "设定", "记录"]
            ),
            let cleaned = cleanedCalendarSummary(semantic)
        {
            return cleaned
        }

        return "日程"
    }

    private func cleanedCalendarSummary(_ text: String) -> String? {
        let stripped = text
            .replacingOccurrences(
                of: #"(今天|明天|后天|上午|中午|下午|晚上|凌晨|周[一二三四五六日天]|本周|下周|这周|\\d{1,2}月\\d{1,2}日|\\d{1,2}[:：]\\d{2}|\\d{1,2}点半?|\\d{1,2}点)"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        let banned = Set(["飞书", "日程", "日历", "会议", "行程", "课程", "提醒", "一个", "一条"])
        let compact = stripped.replacingOccurrences(of: " ", with: "")
        if compact.isEmpty || banned.contains(compact) {
            return nil
        }
        return String(stripped.prefix(50))
    }

    private func firstQuotedText(in text: String) -> String? {
        let patterns = [
            #""([^"]+)""#,
            #"“([^”]+)”"#,
            #"‘([^’]+)’"#,
            #"「([^」]+)」"#
        ]
        for pattern in patterns {
            if let captured = textMatched(in: text, pattern: pattern) {
                return captured
            }
        }
        return nil
    }

    private func textMatched(
        in text: String,
        pattern: String,
        captureGroup: Int = 1
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            match.numberOfRanges > captureGroup,
            let matchedRange = Range(match.range(at: captureGroup), in: text)
        else {
            return nil
        }
        return String(text[matchedRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detectedDates(in text: String) -> [Date] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return detector
            .matches(in: text, options: [], range: range)
            .compactMap(\.date)
            .sorted()
    }

    private func iso8601LocalString(from date: Date) -> String {
        Self.iso8601Local.string(from: date)
    }

    private static let iso8601Local: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    private func inferredInlineIMSendArguments(from spokenCommand: String) -> [String]? {
        guard let message = inferredMessageBody(from: spokenCommand) else {
            return nil
        }
        if let chatID = extractedIdentifier(in: spokenCommand, prefix: "oc_") {
            return ["--chat-id", chatID, "--text", message]
        }
        if let userID = extractedIdentifier(in: spokenCommand, prefix: "ou_") {
            return ["--user-id", userID, "--text", message]
        }
        return nil
    }

    private func autoResolvedIMMessagePlan(
        spokenCommand: String,
        backend: FeishuCLIBackendDescriptor,
        fallbackPlan: FeishuCLICommandPlan
    ) async -> FeishuCLICommandPlan? {
        guard let message = inferredMessageBody(from: spokenCommand) else {
            return nil
        }
        guard let target = await resolveIMTargetID(from: spokenCommand, backend: backend) else {
            return nil
        }

        let args = [
            "im",
            "+messages-send",
            "--as",
            "bot",
            target.flag,
            target.value,
            "--text",
            message
        ]

        return FeishuCLICommandPlan(
            executablePath: fallbackPlan.executablePath,
            arguments: args,
            summary: "发送消息（自动解析目标）",
            riskLevel: .write,
            executionMode: .execute
        )
    }

    private func resolveIMTargetID(
        from spokenCommand: String,
        backend: FeishuCLIBackendDescriptor
    ) async -> (flag: String, value: String)? {
        if let chatID = extractedIdentifier(in: spokenCommand, prefix: "oc_") {
            return ("--chat-id", chatID)
        }
        if let userID = extractedIdentifier(in: spokenCommand, prefix: "ou_") {
            return ("--user-id", userID)
        }

        guard let recipientHint = inferredRecipientHint(from: spokenCommand) else {
            return nil
        }

        if let chatID = await resolveChatID(query: recipientHint, backend: backend) {
            return ("--chat-id", chatID)
        }
        if let userID = await resolveUserID(query: recipientHint, backend: backend) {
            return ("--user-id", userID)
        }
        return nil
    }

    private func resolveChatID(
        query: String,
        backend: FeishuCLIBackendDescriptor
    ) async -> String? {
        let result = await runProcessWithTimeout(
            executablePath: backend.executablePath,
            arguments: ["im", "+chat-search", "--query", query, "--format", "json"],
            timeoutSeconds: 8,
            maxOutputCharacters: 6_000,
            environment: Self.buildProcessEnvironment(executablePath: backend.executablePath)
        )
        guard result.exitCode == 0 else {
            return nil
        }
        guard
            let data = result.stdout.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let payload = dictionary["data"] as? [String: Any],
            let chats = payload["chats"] as? [[String: Any]],
            let first = chats.first,
            let chatID = first["chat_id"] as? String
        else {
            return nil
        }
        let normalized = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func resolveUserID(
        query: String,
        backend: FeishuCLIBackendDescriptor
    ) async -> String? {
        let result = await runProcessWithTimeout(
            executablePath: backend.executablePath,
            arguments: ["contact", "+search-user", "--query", query, "--format", "json"],
            timeoutSeconds: 8,
            maxOutputCharacters: 6_000,
            environment: Self.buildProcessEnvironment(executablePath: backend.executablePath)
        )
        guard result.exitCode == 0 else {
            return nil
        }
        guard
            let data = result.stdout.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let payload = dictionary["data"] as? [String: Any],
            let users = payload["users"] as? [[String: Any]],
            let first = users.first,
            let userID = first["open_id"] as? String
        else {
            return nil
        }
        let normalized = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func inferredMessageBody(from spokenCommand: String) -> String? {
        if let quoted = firstQuotedText(in: spokenCommand) {
            return String(quoted.prefix(200))
        }

        let patterns = [
            #"(?:告诉(?:他|她)?|内容(?:是|为)?|说(?:一下)?|message is)\s*[：:，,]?\s*(.+)$"#,
            #"(?:发消息(?:给|到)?[^，,。]*)[，,]\s*(.+)$"#
        ]
        for pattern in patterns {
            if
                let captured = textMatched(in: spokenCommand, pattern: pattern),
                !captured.isEmpty
            {
                let normalized = captured
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                guard !normalized.isEmpty else {
                    continue
                }
                return String(normalized.prefix(200))
            }
        }
        return nil
    }

    private func inferredRecipientHint(from spokenCommand: String) -> String? {
        let patterns = [
            #"(?:给|发给)\s*(.+?)(?:发消息|消息|说|告诉|，|,|。|$)"#,
            #"(?:to)\s*(.+?)(?:message|say|,|$)"#
        ]
        for pattern in patterns {
            if let captured = textMatched(in: spokenCommand, pattern: pattern) {
                let cleaned = captured
                    .replacingOccurrences(of: "飞书的", with: "")
                    .replacingOccurrences(of: "飞书", with: "")
                    .replacingOccurrences(of: "lark 的", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "lark", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                guard !cleaned.isEmpty else {
                    continue
                }
                return String(cleaned.prefix(64))
            }
        }
        return nil
    }

    private func extractedIdentifier(in text: String, prefix: String) -> String? {
        let escapedPrefix = NSRegularExpression.escapedPattern(for: prefix)
        guard let regex = try? NSRegularExpression(pattern: "\\b\(escapedPrefix)[A-Za-z0-9]+\\b") else {
            return nil
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            let matchedRange = Range(match.range, in: text)
        else {
            return nil
        }
        let value = String(text[matchedRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func isExecutableAllowed(_ executablePath: String) -> Bool {
        let name = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
        return name == "feishu" || name == "lark-cli"
    }

    private func mergedOutput(from result: MagicianProcessResult) -> String {
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if !stdout.isEmpty {
            return stdout
        }
        if !stderr.isEmpty {
            return stderr
        }
        return ""
    }

    private func isLikelyAuthError(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        let keywords = [
            "auth",
            "token",
            "login",
            "unauthorized",
            "permission",
            "scope",
            "not configured",
            "config init",
            "device code",
            "oauth",
            "请先登录",
            "未登录",
            "授权"
        ]
        return keywords.contains(where: lowered.contains)
    }

    private func containsAny(_ text: String, keywords: [String]) -> Bool {
        let lowered = text.lowercased()
        return keywords.contains(where: { lowered.contains($0.lowercased()) })
    }

    private static func resolveExecutable(
        named commandName: String,
        fileManager: FileManager,
        directories: [String]
    ) -> String? {
        if commandName.contains("/") {
            return nil
        }

        for directory in directories {
            let fullPath = (directory as NSString).appendingPathComponent(commandName)
            if fileManager.isExecutableFile(atPath: fullPath) {
                return URL(fileURLWithPath: fullPath).standardizedFileURL.path
            }
        }
        return nil
    }

    private static func resolveOverrideExecutable(
        _ overridePath: String?,
        fileManager: FileManager
    ) -> String? {
        guard
            let overridePath = overridePath?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !overridePath.isEmpty
        else {
            return nil
        }

        let expandedPath = (overridePath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory)
        guard exists else {
            return nil
        }

        if isDirectory.boolValue {
            for command in ["lark-cli", "feishu"] {
                let candidate = (expandedPath as NSString).appendingPathComponent(command)
                if fileManager.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate).standardizedFileURL.path
                }
            }
            return nil
        }

        guard fileManager.isExecutableFile(atPath: expandedPath) else {
            return nil
        }
        return URL(fileURLWithPath: expandedPath).standardizedFileURL.path
    }

    private static func backendDescriptor(for executablePath: String) -> FeishuCLIBackendDescriptor? {
        let name = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
        switch name {
        case "lark-cli":
            return FeishuCLIBackendDescriptor(
                kind: .larkCLI,
                executablePath: executablePath,
                commandName: "lark-cli"
            )
        case "feishu":
            return FeishuCLIBackendDescriptor(
                kind: .feishu,
                executablePath: executablePath,
                commandName: "feishu"
            )
        default:
            return nil
        }
    }

    private static func mergedSearchDirectories(
        pathDirectories: [String],
        fallbackDirectories: [String],
        additionalDirectories: [String]
    ) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()
        for raw in pathDirectories + additionalDirectories + fallbackDirectories {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let normalized = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
                .standardizedFileURL
                .path
            guard seen.insert(normalized).inserted else {
                continue
            }
            merged.append(normalized)
        }
        return merged
    }

    private static func defaultSearchDirectories(
        environment: [String: String]
    ) -> [String] {
        let homeDirectory = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var directories: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        if !homeDirectory.isEmpty {
            directories.append("\(homeDirectory)/.local/bin")
            directories.append("\(homeDirectory)/.npm-global/bin")
            directories.append("\(homeDirectory)/.bun/bin")
            directories.append("\(homeDirectory)/Library/pnpm")
        }
        return directories
    }
}

func runProcessWithTimeout(
    executablePath: String,
    arguments: [String],
    timeoutSeconds: TimeInterval,
    maxOutputCharacters: Int,
    environment: [String: String]? = nil
) async -> MagicianProcessResult {
    await Task.detached(priority: .userInitiated) {
        runProcessWithTimeoutSync(
            executablePath: executablePath,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            maxOutputCharacters: maxOutputCharacters,
            environment: environment
        )
    }.value
}

private func runProcessWithTimeoutSync(
    executablePath: String,
    arguments: [String],
    timeoutSeconds: TimeInterval,
    maxOutputCharacters: Int,
    environment: [String: String]?
) -> MagicianProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return MagicianProcessResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        let timedOut = semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut
        if timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.6)
            if process.isRunning {
                #if canImport(Darwin)
                Darwin.kill(process.processIdentifier, SIGKILL)
                #endif
                _ = semaphore.wait(timeout: .now() + 0.4)
            }
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        let truncatedStdout = truncateCLIOutput(stdoutText, maxCharacters: maxOutputCharacters)
        let truncatedStderr = truncateCLIOutput(stderrText, maxCharacters: maxOutputCharacters)

        if timedOut {
            let detail = truncatedStderr.isEmpty ? "process timed out" : truncatedStderr
            return MagicianProcessResult(
                exitCode: -998,
                stdout: truncatedStdout,
                stderr: detail
            )
        }

        return MagicianProcessResult(
            exitCode: process.terminationStatus,
            stdout: truncatedStdout,
            stderr: truncatedStderr
        )
}

private func truncateCLIOutput(_ text: String, maxCharacters: Int) -> String {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > maxCharacters else {
        return normalized
    }

    let prefix = normalized.prefix(max(0, maxCharacters - 32))
    return "\(prefix)\n... output truncated ..."
}

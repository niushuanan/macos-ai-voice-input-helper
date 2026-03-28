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

        let rules: [(FeishuCanonicalOperation, [String])] = [
            (.oauthBatchAuth, ["批量授权", "batch auth"]),
            (.oauth, ["oauth", "授权", "登录飞书", "飞书登录", "auth"]),
            (.calendarFreebusy, ["忙闲", "freebusy", "空闲"]),
            (.calendarEventAttendee, ["参会", "attendee", "邀请"]),
            (.calendarEvent, ["日程", "议程", "会议", "calendar event", "agenda"]),
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
}

struct FeishuCLICommandPlan: Equatable {
    let executablePath: String
    let arguments: [String]
    let summary: String
    let riskLevel: FeishuCLIRiskLevel
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
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FeishuCLIAvailability {
        if let resolved = resolveExecutable(named: "feishu", fileManager: fileManager, environment: environment) {
            return FeishuCLIAvailability(
                backend: FeishuCLIBackendDescriptor(
                    kind: .feishu,
                    executablePath: resolved,
                    commandName: "feishu"
                )
            )
        }

        if let resolved = resolveExecutable(named: "lark-cli", fileManager: fileManager, environment: environment) {
            return FeishuCLIAvailability(
                backend: FeishuCLIBackendDescriptor(
                    kind: .larkCLI,
                    executablePath: resolved,
                    commandName: "lark-cli"
                )
            )
        }

        return .unavailable
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

        let plan = makeCommandPlan(
            operation: operation,
            spokenCommand: spokenCommand,
            explicitArguments: explicitArguments,
            backend: backend
        )

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
            maxOutputCharacters: Self.maxOutputCharacters
        )

        if processResult.exitCode == 0 {
            let output = mergedOutput(from: processResult)
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
                riskLevel: operation.riskLevel
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
                riskLevel: operation.riskLevel
            )
        }
    }

    private func larkCLIArguments(
        operation: FeishuCanonicalOperation,
        spokenCommand: String,
        explicitArguments: [String]
    ) -> [String] {
        var args: [String]

        switch operation {
        case .bitableApp:
            args = ["base", "+base-get", "--help"]
        case .bitableAppTable:
            args = ["base", "+table-list", "--help"]
        case .bitableAppTableField:
            args = ["base", "+field-list", "--help"]
        case .bitableAppTableRecord:
            args = ["base", "+record-list", "--help"]
        case .bitableAppTableView:
            args = ["base", "+view-list", "--help"]
        case .calendarCalendar:
            args = ["calendar", "+agenda"]
        case .calendarEvent:
            if containsAny(spokenCommand, keywords: ["创建", "新建", "安排", "建", "create"]) {
                args = ["calendar", "+create", "--help"]
            } else {
                args = ["calendar", "+agenda"]
            }
        case .calendarEventAttendee:
            args = ["calendar", "+create", "--help"]
        case .calendarFreebusy:
            args = ["calendar", "+freebusy", "--help"]
        case .chat:
            args = ["im", "+chat-search", "--help"]
        case .chatMembers:
            args = ["im", "+chat-search", "--help"]
        case .createDoc:
            args = ["docs", "+create", "--help"]
        case .docComments:
            args = ["drive", "+add-comment", "--help"]
        case .docMedia:
            if containsAny(spokenCommand, keywords: ["下载", "download"]) {
                args = ["docs", "+media-download", "--help"]
            } else {
                args = ["docs", "+media-upload", "--help"]
            }
        case .driveFile:
            if containsAny(spokenCommand, keywords: ["上传", "upload"]) {
                args = ["drive", "+upload", "--help"]
            } else {
                args = ["drive", "+download", "--help"]
            }
        case .fetchDoc:
            args = ["docs", "+fetch", "--help"]
        case .getUser:
            args = ["contact", "+get-user", "--help"]
        case .imBotImage:
            args = ["im", "+messages-send", "--help"]
        case .imUserFetchResource:
            args = ["im", "+messages-resources-download", "--help"]
        case .imUserGetMessages:
            args = ["im", "+chat-messages-list", "--help"]
        case .imUserGetThreadMessages:
            args = ["im", "+threads-messages-list", "--help"]
        case .imUserMessage:
            if containsAny(spokenCommand, keywords: ["回复", "reply"]) {
                args = ["im", "+messages-reply", "--help"]
            } else {
                args = ["im", "+messages-send", "--help"]
            }
        case .imUserSearchMessages:
            args = ["im", "+messages-search", "--help"]
        case .oauth:
            args = ["auth", "status", "--format", "json"]
        case .oauthBatchAuth:
            args = ["auth", "login", "--help"]
        case .searchDocWiki:
            args = ["docs", "+search", "--help"]
        case .searchUser:
            args = ["contact", "+search-user", "--help"]
        case .sheet:
            if containsAny(spokenCommand, keywords: ["写", "追加", "append", "write"]) {
                args = ["sheets", "+write", "--help"]
            } else {
                args = ["sheets", "+read", "--help"]
            }
        case .taskComment:
            args = ["task", "+comment", "--help"]
        case .taskSubtask:
            args = ["task", "+create", "--help"]
        case .taskTask:
            if containsAny(spokenCommand, keywords: ["更新", "update", "完成", "complete"]) {
                args = ["task", "+update", "--help"]
            } else {
                args = ["task", "+create", "--help"]
            }
        case .taskTasklist:
            args = ["task", "+tasklist-create", "--help"]
        case .updateDoc:
            args = ["docs", "+update", "--help"]
        case .wikiSpace:
            args = ["docs", "+search", "--help"]
        case .wikiSpaceNode:
            args = ["docs", "+fetch", "--help"]
        }

        return args + sanitizedExplicitArguments(explicitArguments)
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
        environment: [String: String]
    ) -> String? {
        if commandName.contains("/") {
            return nil
        }

        let path = environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init)
        for directory in directories {
            let fullPath = (directory as NSString).appendingPathComponent(commandName)
            if fileManager.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }
}

func runProcessWithTimeout(
    executablePath: String,
    arguments: [String],
    timeoutSeconds: TimeInterval,
    maxOutputCharacters: Int
) async -> MagicianProcessResult {
    await Task.detached(priority: .userInitiated) {
        runProcessWithTimeoutSync(
            executablePath: executablePath,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            maxOutputCharacters: maxOutputCharacters
        )
    }.value
}

private func runProcessWithTimeoutSync(
    executablePath: String,
    arguments: [String],
    timeoutSeconds: TimeInterval,
    maxOutputCharacters: Int
) -> MagicianProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

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

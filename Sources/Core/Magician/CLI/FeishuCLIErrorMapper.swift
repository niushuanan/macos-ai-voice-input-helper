import Foundation

struct FeishuCLIErrorMapper {
    func missingArgumentMessage(for operation: FeishuCanonicalOperation) -> String {
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

    func userFacingCLIErrorMessage(
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
        if lowered.contains("required flag") || lowered.contains("missing required") {
            return missingArgumentMessage(for: operation)
        }
        if lowered.contains("unknown flag") || lowered.contains("unknown shorthand flag") {
            return "命令参数格式不正确，请检查参数写法后再试。"
        }
        if lowered.contains("not found") || lowered.contains("does not exist") {
            return "目标对象不存在，请先确认用户、群聊或资源是否可访问。"
        }
        if lowered.contains("more than one") || lowered.contains("ambiguous") {
            return "目标不够唯一，请补充更具体的对象后再试。"
        }
        if operation == .calendarEvent, lowered.contains("start") {
            return "日程时间参数不合法，请补充更明确的日期和时间。"
        }
        return "飞书 CLI 返回失败：\(message)"
    }

    func normalizedExecutionFailureMessage(
        detail: String,
        operation: FeishuCanonicalOperation
    ) -> String? {
        let lowered = detail.lowercased()
        if lowered.isEmpty {
            return nil
        }
        if lowered.contains("required flag") || lowered.contains("missing required") {
            return missingArgumentMessage(for: operation)
        }
        if lowered.contains("unknown flag") || lowered.contains("unknown shorthand flag") {
            return "飞书 CLI 参数格式不正确，请检查参数后重试。"
        }
        if lowered.contains("permission denied") || lowered.contains("scope") {
            return "飞书权限不足，请检查 app scope 并重新授权。"
        }
        if lowered.contains("not found") || lowered.contains("does not exist") {
            return "目标对象不存在，请确认用户、群聊或资源标识是否正确。"
        }
        if lowered.contains("more than one") || lowered.contains("ambiguous") {
            return "目标不够唯一，请补充更具体的信息后再试。"
        }
        return nil
    }

    func isLikelyAuthError(_ detail: String) -> Bool {
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
}

import Foundation

enum V4LoopDecisionAction: String, Codable, Equatable, Sendable {
    case `continue`
    case finish
    case askUser = "ask_user"
    case fail
}

struct V4LoopDecision: Codable, Equatable, Sendable {
    let action: V4LoopDecisionAction
    let message: String
    let failureCode: V4FailureCode?

    init(
        action: V4LoopDecisionAction,
        message: String,
        failureCode: V4FailureCode? = nil
    ) {
        self.action = action
        self.message = message
        self.failureCode = failureCode
    }
}

struct V4Plan: Codable, Equatable, Sendable {
    let steps: [V4StepRecord]
    let terminalDecision: V4LoopDecision?

    init(
        steps: [V4StepRecord],
        terminalDecision: V4LoopDecision? = nil
    ) {
        self.steps = steps
        self.terminalDecision = terminalDecision
    }
}

enum V4VerificationStatus: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case needsUserInput = "needs_user_input"
}

struct V4VerificationResult: Codable, Equatable, Sendable {
    let status: V4VerificationStatus
    let message: String
    let evidenceSummary: String

    init(
        status: V4VerificationStatus,
        message: String,
        evidenceSummary: String = ""
    ) {
        self.status = status
        self.message = message
        self.evidenceSummary = evidenceSummary
    }
}

protocol V4Planner: Sendable {
    /// 基于当前 run request 产出首轮或下一轮 step 计划。
    func plan(for request: V4RunRequest) async throws -> V4Plan
}

protocol V4PostStepDecider: Sendable {
    /// 在一个 step 完成后判断是否继续、结束、问用户或失败。
    func decide(
        after latestStep: V4StepRecord,
        accumulatedStepRecords: [V4StepRecord],
        latestToolResult: V4ToolResult?,
        latestVerification: V4VerificationResult,
        for request: V4RunRequest
    ) async -> V4LoopDecision
}

protocol V4Verifier: Sendable {
    /// 对当前 run 的 step records 与 tool result 生成核验结果与聚合证据。
    func verify(
        for request: V4RunRequest,
        stepRecords: [V4StepRecord],
        latestToolResult: V4ToolResult?
    ) async -> V4VerificationResult
}

protocol V4AgentLoopRunning: Sendable {
    /// 执行一次完整的 V4 run，并在关键节点吐出结构化事件。
    func run(
        request: V4RunRequest,
        onEvent: (@Sendable (V4RuntimeEvent) -> Void)?
    ) async throws -> V4RunOutcome
}

enum MagicianLane {
    case nativeFast
    case agent
    case unsupportedMixedExternal
}

struct MagicianLaneDecision {
    let lane: MagicianLane
    let reason: String
    let userMessage: String?
}

private enum MagicianLaneExternalAction: String, Hashable {
    case mail
    case note
    case calendar
    case music
    case feishu
}

struct MagicianLaneClassifier {
    func decide(
        command: String,
        selectionSnapshot: FocusedSelectionSnapshot?,
        enabledFeatures _: Set<MagicianFeatureID>
    ) -> MagicianLaneDecision {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasSelection = !(selectionSnapshot?.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard !normalized.isEmpty else {
            return MagicianLaneDecision(
                lane: .nativeFast,
                reason: "empty_command",
                userMessage: nil
            )
        }

        var actions = Set<MagicianLaneExternalAction>()
        let containsExplicitFeishuFamily = magicianContainsExplicitFeishuFamily(normalized)
        let containsFeishuIntent = magicianContainsFeishuIntent(normalized)
        if containsFeishuIntent {
            actions.insert(.feishu)
        }
        if magicianValueContainsAny(normalized, tokens: ["邮件", "mail", "email", "草稿", "发邮件", "写邮件", "邮箱", "收件人"]) {
            actions.insert(.mail)
        }
        if magicianValueContainsAny(
            normalized,
            tokens: [
                "备忘录", "note", "notes", "记下来", "记到", "写进备忘录", "写入备忘录",
                "写进文档", "写入文档", "记到文档", "记录到文档", "写到文档", "放到文档", "放进文档"
            ]
        ) {
            actions.insert(.note)
        }
        if magicianShouldTreatAsNativeCalendarIntent(
            normalized,
            containsExplicitFeishuFamily: containsExplicitFeishuFamily
        ) {
            actions.insert(.calendar)
        }
        if magicianValueContainsAny(normalized, tokens: ["音乐", "歌曲", "播放", "暂停", "继续播放", "下一首", "上一首", "music", "play", "pause"]) {
            actions.insert(.music)
        }

        if actions.contains(.feishu), actions.count > 1 {
            return MagicianLaneDecision(
                lane: .unsupportedMixedExternal,
                reason: "mixed_feishu_and_native",
                userMessage: "这条命令同时跨了飞书和苹果原生能力，请拆开说。"
            )
        }

        if actions.count > 1 {
            if actions.contains(.music) {
                return MagicianLaneDecision(
                    lane: .unsupportedMixedExternal,
                    reason: "music_mixed_with_other_external",
                    userMessage: "音乐控制不能和其他外部动作混在一条命令里，请拆开说。"
                )
            }
            return MagicianLaneDecision(
                lane: .unsupportedMixedExternal,
                reason: "multiple_native_external_actions",
                userMessage: "一条命令里同时驱动多个外部动作还不支持，请拆开说。"
            )
        }

        if actions.contains(.feishu) {
            return MagicianLaneDecision(
                lane: .agent,
                reason: "feishu_or_external_skill",
                userMessage: nil
            )
        }

        if looksLikeAgentOnlyTask(normalized) {
            return MagicianLaneDecision(
                lane: .agent,
                reason: "research_or_shell_task",
                userMessage: nil
            )
        }

        if hasSelection || actions.isEmpty {
            return MagicianLaneDecision(
                lane: .nativeFast,
                reason: actions.isEmpty ? "pure_text_or_native_default" : "native_fast_action",
                userMessage: nil
            )
        }

        return MagicianLaneDecision(
            lane: .nativeFast,
            reason: "native_fast_action",
            userMessage: nil
        )
    }

    private func looksLikeAgentOnlyTask(_ value: String) -> Bool {
        magicianValueContainsAny(
            value,
            tokens: [
                "终端", "命令行", "shell", "zsh", "bash",
                "git ", "npm ", "pnpm ", "yarn ", "python ", "node ", "swift ", "xcodebuild",
                "联网", "查资料", "网页", "浏览器", "搜索网页", "调研", "最新情况", "最近新闻"
            ]
        )
    }
}

func magicianContainsFeishuIntent(_ value: String) -> Bool {
    if magicianContainsExplicitFeishuFamily(value) {
        return true
    }
    guard let operation = FeishuCanonicalOperation.infer(from: value) else {
        return false
    }
    switch operation {
    case .calendarCalendar, .calendarEvent, .calendarEventAttendee, .calendarFreebusy:
        return false
    default:
        return true
    }
}

func magicianContainsExplicitFeishuFamily(_ value: String) -> Bool {
    magicianValueContainsAny(value, tokens: ["飞书", "feishu", "lark"])
}

func magicianShouldTreatAsNativeCalendarIntent(
    _ value: String,
    containsExplicitFeishuFamily: Bool? = nil
) -> Bool {
    guard magicianLooksLikeNativeCalendarIntent(value) else {
        return false
    }
    let hasExplicitFeishuFamily = containsExplicitFeishuFamily ?? magicianContainsExplicitFeishuFamily(value)
    guard hasExplicitFeishuFamily else {
        return true
    }
    return magicianLooksLikeCalendarAndFeishuMixedIntent(value)
}

private func magicianLooksLikeCalendarAndFeishuMixedIntent(_ value: String) -> Bool {
    magicianRegexMatch(
        value,
        pattern: #"(同步|发给|发到|发送到|推送到|同步到).*(飞书|feishu|lark)"#
    )
}

private func magicianLooksLikeNativeCalendarIntent(_ value: String) -> Bool {
    if magicianValueContainsAny(value, tokens: ["日历", "calendar", "event", "日程", "行程"]) {
        return true
    }
    return magicianRegexMatch(
        value,
        pattern: #"(添加|新增|创建|建立|安排|加一个|设定|提醒).*(日程|行程|会议|课程|上课)"#
    ) || magicianRegexMatch(
        value,
        pattern: #"(今天|明天|后天|上午|下午|晚上|周[一二三四五六日天]|\d+点|:\d{2}).*(日程|行程|会议|课程|上课)"#
    )
}

private func magicianValueContainsAny(_ value: String, tokens: [String]) -> Bool {
    tokens.contains { value.contains($0) }
}

private func magicianRegexMatch(_ value: String, pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return false
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.firstMatch(in: value, options: [], range: range) != nil
}

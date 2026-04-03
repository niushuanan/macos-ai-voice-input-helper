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
}

enum MagicianSelectionMode {
    case none
    case optional
    case required
}

enum MagicianExecutionPath {
    case musicFast
    case plannerV4
}

enum MagicianNormalizedIntent: String, Codable {
    case play
    case pause
    case resume
    case next
    case previous
    case open
}

struct MagicianLaneDecision {
    let lane: MagicianLane
    let reason: String
    let userMessage: String?
    let selectionMode: MagicianSelectionMode
    let executionPath: MagicianExecutionPath
    let normalizedIntent: MagicianNormalizedIntent?
    let normalizedQuery: String?

    init(
        lane: MagicianLane,
        reason: String,
        userMessage: String?,
        selectionMode: MagicianSelectionMode = .optional,
        executionPath: MagicianExecutionPath = .plannerV4,
        normalizedIntent: MagicianNormalizedIntent? = nil,
        normalizedQuery: String? = nil
    ) {
        self.lane = lane
        self.reason = reason
        self.userMessage = userMessage
        self.selectionMode = selectionMode
        self.executionPath = executionPath
        self.normalizedIntent = normalizedIntent
        self.normalizedQuery = normalizedQuery
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

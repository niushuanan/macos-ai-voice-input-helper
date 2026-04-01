import Foundation

enum V4RuntimeEventName: String, Codable, Equatable, Sendable {
    case requestAccepted = "request_accepted"
    case stateChanged = "state_changed"
    case planReady = "plan_ready"
    case stepStarted = "step_started"
    case stepFinished = "step_finished"
    case toolRequested = "tool_requested"
    case toolFinished = "tool_finished"
    case verificationFinished = "verification_finished"
    case runCompleted = "run_completed"
    case runFailed = "run_failed"
}

struct V4RunRequest: Codable, Equatable, Sendable {
    /// 当前会话标识，后续桥到 `SessionStore` 与历史库。
    let sessionID: V4SessionID
    /// 当前 run 标识，后续桥到历史与时光机。
    let runID: V4RunID
    /// 跨日志链路的追踪标识。
    let traceID: V4TraceID
    /// 当前请求所在 lane。
    let lane: V4Lane
    /// 当前请求的目标摘要，供 planner、prompt、history 复用。
    let goalSummary: String
    /// 用户原始输入文本或转写文本。
    let inputText: String
    /// 当前应用名快照，后续桥到历史记录。
    let appName: String?
    /// 当前应用 bundle id 快照，后续桥到历史记录。
    let bundleID: String?
    /// 当前选中文本快照，供 rewrite lane 与 tool lane 使用。
    let selectionText: String?
    /// 当前 run 已累计的 step records，首轮默认空数组。
    let stepRecords: [V4StepRecord]
    /// 当前 run 的证据摘要，首轮可为空字符串。
    let evidenceSummary: String
    /// 请求创建时间，用于历史排序与时光机时间线。
    let requestedAt: Date

    init(
        sessionID: V4SessionID = V4SessionID(),
        runID: V4RunID = V4RunID(),
        traceID: V4TraceID = V4TraceID(),
        lane: V4Lane,
        goalSummary: String,
        inputText: String,
        appName: String? = nil,
        bundleID: String? = nil,
        selectionText: String? = nil,
        stepRecords: [V4StepRecord] = [],
        evidenceSummary: String = "",
        requestedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.traceID = traceID
        self.lane = lane
        self.goalSummary = goalSummary
        self.inputText = inputText
        self.appName = appName
        self.bundleID = bundleID
        self.selectionText = selectionText
        self.stepRecords = stepRecords
        self.evidenceSummary = evidenceSummary
        self.requestedAt = requestedAt
    }
}

struct V4RuntimeEvent: Codable, Equatable, Sendable {
    /// 事件名，供 bridge 与日志层做状态分流。
    let name: V4RuntimeEventName
    /// 事件发生时的 run 状态快照。
    let status: V4RunStatus
    /// 事件所属会话标识。
    let sessionID: V4SessionID
    /// 事件所属 run 标识。
    let runID: V4RunID
    /// 跨日志链路的追踪标识。
    let traceID: V4TraceID
    /// 事件所在 lane。
    let lane: V4Lane
    /// 事件对应的目标摘要。
    let goalSummary: String
    /// 当前进度提示文本，后续桥到 HUD 与调试日志。
    let message: String
    /// 当前事件对应的 step 标识，没有 step 时为空。
    let stepID: V4StepID?
    /// 当前 run 已累计的 step records 快照。
    let stepRecords: [V4StepRecord]
    /// 当前 run 的证据摘要快照。
    let evidenceSummary: String
    /// 0...1 的进度提示，后续桥到 HUD。
    let progressHint: Double?
    /// 事件创建时间，便于回放与排序。
    let createdAt: Date
}

struct V4StepRecord: Codable, Equatable, Sendable, Identifiable {
    /// 单个 step 的稳定标识。
    let id: V4StepID
    /// 该 step 所属 trace 标识。
    let traceID: V4TraceID
    /// 该 step 所属 lane。
    let lane: V4Lane
    /// 该 step 对应的目标摘要。
    let goalSummary: String
    /// step 的展示标题，面向日志、调试页与 history 摘要。
    let title: String
    /// step 当前状态。
    let status: V4RunStatus
    /// 该 step 绑定的 tool 名，没有 tool 时为空。
    let toolName: String?
    /// step 输入摘要，避免把大段原文直接塞进日志 UI。
    let inputSummary: String
    /// step 输出摘要，成功或失败后补齐。
    let outputSummary: String?
    /// 该 step 的证据摘要，供 verifier 与 history 聚合。
    let evidenceSummary: String
    /// step 开始时间。
    let startedAt: Date
    /// step 结束时间，未结束时为空。
    let finishedAt: Date?
    /// step 失败码，没有失败时为空。
    let failureCode: V4FailureCode?

    init(
        id: V4StepID = V4StepID(),
        traceID: V4TraceID,
        lane: V4Lane,
        goalSummary: String,
        title: String,
        status: V4RunStatus,
        toolName: String? = nil,
        inputSummary: String,
        outputSummary: String? = nil,
        evidenceSummary: String = "",
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        failureCode: V4FailureCode? = nil
    ) {
        self.id = id
        self.traceID = traceID
        self.lane = lane
        self.goalSummary = goalSummary
        self.title = title
        self.status = status
        self.toolName = toolName
        self.inputSummary = inputSummary
        self.outputSummary = outputSummary
        self.evidenceSummary = evidenceSummary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.failureCode = failureCode
    }
}

struct V4RunOutcome: Codable, Equatable, Sendable {
    /// 最终结果所属会话标识。
    let sessionID: V4SessionID
    /// 最终结果所属 run 标识。
    let runID: V4RunID
    /// 跨日志链路的追踪标识。
    let traceID: V4TraceID
    /// 最终结果所在 lane。
    let lane: V4Lane
    /// 最终目标摘要。
    let goalSummary: String
    /// run 结束时的状态。
    let status: V4RunStatus
    /// 面向用户或日志展示的状态文本。
    let finalStatusMessage: String
    /// 最终输出文本，没有写回文本时为空。
    let finalOutputText: String?
    /// UI 与历史列表使用的短展示文本。
    let displayText: String
    /// 当前 run 的全部 step records。
    let stepRecords: [V4StepRecord]
    /// run 聚合后的证据摘要。
    let evidenceSummary: String
    /// 失败码，成功时为空。
    let failureCode: V4FailureCode?
    /// run 结束时间。
    let finishedAt: Date
}

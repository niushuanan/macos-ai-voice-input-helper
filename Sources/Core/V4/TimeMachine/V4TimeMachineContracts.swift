import Foundation

struct V4TimeItem: Codable, Equatable, Sendable, Identifiable {
    /// 时间线条目标识。
    let id: String
    /// 对应会话标识，没有会话时为空。
    let sessionID: V4SessionID?
    /// 对应 run 标识，没有 run 时为空。
    let runID: V4RunID?
    /// 跨日志链路的追踪标识，没有 trace 时为空。
    let traceID: V4TraceID?
    /// 当前时间线条目所属 lane，没有 lane 时为空。
    let lane: V4Lane?
    /// 当前时间线条目对应的目标摘要。
    let goalSummary: String
    /// 当前时间线条目的展示标题。
    let title: String
    /// 当前时间线条目的证据摘要。
    let evidenceSummary: String
    /// 当前时间线条目的来源，例如 history / checkpoint / reminder。
    let source: String
    /// 当前时间线条目的发生时间。
    let happenedAt: Date
}

struct V4ReminderSpec: Codable, Equatable, Sendable {
    /// 提醒标识，便于后续与系统 reminder 或 calendar 结果对位。
    let reminderID: String
    /// 提醒标题。
    let title: String
    /// 提醒触发时间。
    let triggerAt: Date
    /// 提醒所属时区标识。
    let timeZoneIdentifier: String
    /// 提醒备注，没有备注时为空。
    let note: String?
    /// 提醒关联的 trace 标识，没有关联时为空。
    let traceID: V4TraceID?
}

struct V4TimeIntent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case timelineLookup = "timeline_lookup"
        case reminderCreate = "reminder_create"
        case replayRun = "replay_run"
        case compareRuns = "compare_runs"
    }

    /// 当前时间意图的种类。
    let kind: Kind
    /// 当前意图发起时的 trace 标识。
    let traceID: V4TraceID
    /// 当前意图所在 lane。
    let lane: V4Lane
    /// 当前意图服务的目标摘要。
    let goalSummary: String
    /// 当前意图的时间锚点，没有显式时间时为空。
    let anchorTime: Date?
    /// 当前意图携带的提醒规格，没有提醒时为空。
    let reminder: V4ReminderSpec?
    /// 当前意图的证据摘要。
    let evidenceSummary: String
}

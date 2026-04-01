import Foundation

enum V4PromptLayerName: String, Codable, CaseIterable, Equatable, Sendable {
    case global = "Global"
    case nowYouSeeMe = "NowYouSeeMe"
    case appScene = "AppScene"
    case timeMachine = "TimeMachine"
    case lane = "Lane"
    case task = "Task"
}

struct V4PromptContext: Codable, Equatable, Sendable {
    /// 跨日志链路的追踪标识。
    let traceID: V4TraceID
    /// 当前 prompt 所在 lane。
    let lane: V4Lane
    /// 当前 prompt 服务的目标摘要。
    let goalSummary: String
    /// 当前原始输入文本。
    let inputText: String
    /// 当前应用名快照，供 scene layer 使用。
    let sourceAppName: String?
    /// 当前应用 bundle id 快照，供 scene layer 使用。
    let sourceBundleID: String?
    /// 当前选中文本快照，供 rewrite lane 使用。
    let selectionText: String?
    /// 当前 run 已累计的 step records，供 tool-result layer 与 memory layer 参考。
    let stepRecords: [V4StepRecord]
    /// 当前聚合证据摘要，供 memory 与 verification layer 参考。
    let evidenceSummary: String
    /// 请求创建时间。
    let requestedAt: Date

    init(
        traceID: V4TraceID,
        lane: V4Lane,
        goalSummary: String,
        inputText: String,
        sourceAppName: String?,
        sourceBundleID: String?,
        selectionText: String?,
        stepRecords: [V4StepRecord],
        evidenceSummary: String,
        requestedAt: Date
    ) {
        self.traceID = traceID
        self.lane = lane
        self.goalSummary = goalSummary
        self.inputText = inputText
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.selectionText = selectionText
        self.stepRecords = stepRecords
        self.evidenceSummary = evidenceSummary
        self.requestedAt = requestedAt
    }

    init(request: V4RunRequest) {
        self.init(
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            inputText: request.inputText,
            sourceAppName: request.appName,
            sourceBundleID: request.bundleID,
            selectionText: request.selectionText,
            stepRecords: request.stepRecords,
            evidenceSummary: request.evidenceSummary,
            requestedAt: request.requestedAt
        )
    }
}

struct V4PromptLayer: Codable, Equatable, Sendable, Identifiable {
    /// layer 稳定标识，便于调试与排序。
    let id: String
    /// layer 名称，按固定顺序运行。
    let name: V4PromptLayerName
    /// layer 优先级，数值越小越靠前。
    let priority: Int
    /// 当前 layer 贡献的 system prompt 段。
    let systemPrompt: String?
    /// 当前 layer 贡献的 guidance 字段，key 相同则后层覆盖前层。
    let guidance: [String: String]
    /// 当前 layer 贡献的 constraints 字段，key 相同则后层覆盖前层。
    let constraints: [String: String]
    /// 当前 layer 贡献的 user prompt。
    let userPrompt: String?
    /// layer 来源摘要，便于追踪来自哪个 store 或 bridge。
    let sourceSummary: String
    /// 该 layer 是否允许后续窗口做动态改写。
    let isMutable: Bool

    var hasContent: Bool {
        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let userPrompt, !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return !guidance.isEmpty || !constraints.isEmpty
    }
}

struct V4PromptStack: Codable, Equatable, Sendable {
    /// 组装 prompt 时使用的上下文快照。
    let context: V4PromptContext
    /// 参与组装的 prompt layers。
    let appliedLayers: [V4PromptLayer]
    /// 分层拼接后的最终 system prompt。
    let finalSystemPrompt: String
    /// guidance + constraints 渲染后的最终说明。
    let finalGuidancePrompt: String
    /// 最终用户 prompt。
    let finalUserPrompt: String
    /// 合并后的 guidance 字段。
    let guidance: [String: String]
    /// 合并后的 constraints 字段。
    let constraints: [String: String]
    /// 本次注入的规则标识，便于 history 与调试追踪。
    let appliedSkillRuleIDs: [SkillRuleID]
    /// 组装完成时间。
    let createdAt: Date
}

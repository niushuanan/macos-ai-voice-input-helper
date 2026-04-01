import Foundation

struct V4PromptContext: Codable, Equatable, Sendable {
    /// 跨日志链路的追踪标识。
    let traceID: V4TraceID
    /// 当前 prompt 所在 lane。
    let lane: V4Lane
    /// 当前 prompt 服务的目标摘要。
    let goalSummary: String
    /// 当前应用名快照，供 scene layer 使用。
    let sourceAppName: String?
    /// 当前应用 bundle id 快照，供 scene layer 使用。
    let sourceBundleID: String?
    /// 当前选中文本快照，供 rewrite lane 使用。
    let selectionText: String?
    /// 当前可用词典词条，供 dictionary layer 使用。
    let dictionaryTerms: [String]
    /// 当前激活的 skill 标识，供 skill layer 使用。
    let activeSkillIDs: [String]
    /// 当前 run 已累计的 step records，供 tool-result layer 与 memory layer 参考。
    let stepRecords: [V4StepRecord]
    /// 当前聚合证据摘要，供 memory 与 verification layer 参考。
    let evidenceSummary: String
}

struct V4PromptLayer: Codable, Equatable, Sendable, Identifiable {
    /// layer 稳定标识，便于调试与排序。
    let id: String
    /// layer 名称，例如 system / scene / dictionary / memory。
    let name: String
    /// layer 优先级，数值越小越靠前。
    let priority: Int
    /// layer 实际文本内容。
    let content: String
    /// layer 来源摘要，便于追踪来自哪个 store 或 bridge。
    let sourceSummary: String
    /// 该 layer 是否允许后续窗口做动态改写。
    let isMutable: Bool
}

struct V4PromptEnvelope: Codable, Equatable, Sendable {
    /// 跨日志链路的追踪标识。
    let traceID: V4TraceID
    /// 当前 prompt envelope 所在 lane。
    let lane: V4Lane
    /// 当前 prompt 服务的目标摘要。
    let goalSummary: String
    /// 当前 run 已累计的 step records。
    let stepRecords: [V4StepRecord]
    /// 当前聚合证据摘要。
    let evidenceSummary: String
    /// 组装 prompt 时使用的上下文快照。
    let context: V4PromptContext
    /// 参与组装的 prompt layers。
    let layers: [V4PromptLayer]
    /// 最终送给模型的 prompt 文本。
    let renderedPrompt: String
    /// 组装完成时间。
    let createdAt: Date
}

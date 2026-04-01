import Foundation

struct V4MemoryEntry: Codable, Equatable, Sendable, Identifiable {
    /// 记忆条目标识，供检索结果与 timeline 对齐。
    let id: String
    /// 该记忆来源 trace 标识，没有 trace 时为空。
    let traceID: V4TraceID?
    /// 该记忆来源 session 标识，没有 session 时为空。
    let sessionID: V4SessionID?
    /// 该记忆对应 lane，没有 lane 时为空。
    let lane: V4Lane?
    /// 记忆对应的目标摘要。
    let goalSummary: String
    /// 记忆的主文本，通常来自输入、输出或摘要。
    let primaryText: String
    /// 记忆的辅助文本，通常来自指令、对话或 display text。
    let secondaryText: String?
    /// 记忆对应的证据摘要。
    let evidenceSummary: String
    /// 记忆来源说明，例如 history / checkpoint。
    let source: String
    /// 记忆创建时间，用于检索排序与 timeline。
    let createdAt: Date
}

struct V4MemoryQuery: Codable, Equatable, Sendable {
    /// 发起检索时的 trace 标识。
    let traceID: V4TraceID
    /// 发起检索时所在 lane。
    let lane: V4Lane
    /// 发起检索时的目标摘要。
    let goalSummary: String
    /// 当前检索文本。
    let searchText: String
    /// 当前 run 已累计的证据摘要。
    let evidenceSummary: String
    /// 最大返回条数。
    let limit: Int
    /// 可选的时间上界，便于做近邻窗口检索。
    let beforeTime: Date?
    /// 可选的来源过滤条件。
    let sourceFilters: [String]
}

struct V4MemoryHit: Codable, Equatable, Sendable {
    /// 命中的记忆条目。
    let entry: V4MemoryEntry
    /// 检索得分，Window 09 再接具体排序逻辑。
    let score: Double
    /// 命中原因摘要，便于调试召回质量。
    let matchedSummary: String
    /// 命中后整理出的证据摘要。
    let evidenceSummary: String
}

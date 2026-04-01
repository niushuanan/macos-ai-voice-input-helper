import Foundation

protocol V4Planner: Sendable {
    /// 基于当前 run request 产出首轮或下一轮 step 计划。
    func plan(for request: V4RunRequest) async throws -> [V4StepRecord]
}

protocol V4PostStepDecider: Sendable {
    /// 在一个 step 完成后判断是否继续下一轮主循环。
    func shouldContinue(
        after latestStep: V4StepRecord,
        accumulatedStepRecords: [V4StepRecord],
        latestToolResult: V4ToolResult?,
        for request: V4RunRequest
    ) async -> Bool
}

protocol V4Verifier: Sendable {
    /// 对当前 run 的 step records 与 tool result 生成聚合证据摘要。
    func buildEvidenceSummary(
        for request: V4RunRequest,
        stepRecords: [V4StepRecord],
        latestToolResult: V4ToolResult?
    ) async -> String
}

protocol V4AgentLoopRunning: Sendable {
    /// 执行一次完整的 V4 run，并在关键节点吐出结构化事件。
    func run(
        request: V4RunRequest,
        onEvent: (@Sendable (V4RuntimeEvent) -> Void)?
    ) async throws -> V4RunOutcome
}

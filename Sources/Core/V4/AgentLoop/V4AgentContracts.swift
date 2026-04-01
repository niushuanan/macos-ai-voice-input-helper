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

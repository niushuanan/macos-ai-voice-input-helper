import Foundation

struct V4PostStepDeciderDefault: V4PostStepDecider {
    func decide(
        after latestStep: V4StepRecord,
        accumulatedStepRecords: [V4StepRecord],
        latestToolResult: V4ToolResult?,
        latestVerification: V4VerificationResult,
        for request: V4RunRequest
    ) async -> V4LoopDecision {
        switch latestVerification.status {
        case .needsUserInput:
            return V4LoopDecision(
                action: .askUser,
                message: latestVerification.message,
                failureCode: latestToolResult?.error?.code
            )

        case .failed:
            return V4LoopDecision(
                action: .fail,
                message: latestVerification.message,
                failureCode: latestToolResult?.error?.code ?? latestStep.failureCode ?? .verificationFailed
            )

        case .passed:
            break
        }

        let remainingSegments = V4RulePlannerHeuristics.segments(from: request.inputText).count
        if accumulatedStepRecords.count < remainingSegments {
            return V4LoopDecision(
                action: .continue,
                message: "当前步骤完成，继续下一轮。"
            )
        }

        return V4LoopDecision(
            action: .finish,
            message: latestToolResult?.outputText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? "全部步骤已完成。"
                : "执行已完成。"
        )
    }
}

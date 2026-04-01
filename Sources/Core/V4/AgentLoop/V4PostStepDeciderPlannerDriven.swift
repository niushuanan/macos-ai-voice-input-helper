import Foundation

struct V4PostStepDeciderPlannerDriven: V4PostStepDecider {
    func decide(
        after latestStep: V4StepRecord,
        accumulatedStepRecords _: [V4StepRecord],
        latestToolResult: V4ToolResult?,
        latestVerification: V4VerificationResult,
        for _: V4RunRequest
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
            return V4LoopDecision(
                action: .continue,
                message: "当前步骤已完成，继续规划下一步。"
            )
        }
    }
}

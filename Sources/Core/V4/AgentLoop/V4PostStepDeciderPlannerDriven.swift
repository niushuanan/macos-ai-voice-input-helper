import Foundation

struct V4PostStepDeciderPlannerDriven: V4PostStepDecider {
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

        if request.lane != .selectionRewrite {
            let requiredStepCount = V4RulePlannerHeuristics.segments(from: request.inputText).count
            if accumulatedStepRecords.count >= requiredStepCount {
                let message = latestToolResult?.outputText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? "已完成当前任务。"
                    : "执行已完成。"
                return V4LoopDecision(action: .finish, message: message)
            }
        }

        if hasRepeatedEquivalentStep(in: accumulatedStepRecords) {
            let message = latestToolResult?.outputText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? "结果已产出，停止重复执行。"
                : "检测到重复执行，已停止。"
            return V4LoopDecision(action: .finish, message: message)
        }

        return V4LoopDecision(
            action: .continue,
            message: "当前步骤已完成，继续规划下一步。"
        )
    }

    private func hasRepeatedEquivalentStep(in stepRecords: [V4StepRecord]) -> Bool {
        guard stepRecords.count >= 2 else {
            return false
        }
        let last = stepRecords[stepRecords.count - 1]
        let previous = stepRecords[stepRecords.count - 2]
        guard last.status == .completed, previous.status == .completed else {
            return false
        }
        guard last.toolName == previous.toolName else {
            return false
        }
        let lastOutput = (last.outputSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let previousOutput = (previous.outputSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lastEvidence = last.evidenceSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousEvidence = previous.evidenceSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return !lastOutput.isEmpty && lastOutput == previousOutput && !lastEvidence.isEmpty && lastEvidence == previousEvidence
    }
}

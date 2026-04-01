import Foundation

@MainActor
final class V4MagicianRuntimeAdapter: MagicianAgentRunning {
    private let loopEngine: any V4AgentLoopRunning

    init(loopEngine: (any V4AgentLoopRunning)? = nil) {
        self.loopEngine = loopEngine ?? V4AgentLoopEngine()
    }

    func run(
        request: MagicianAgentRequest,
        onEvent: ((MagicianAgentRuntimeEvent) -> Void)?
    ) async throws -> MagicianAgentRunOutcome {
        let v4Request = V4RunRequest(
            traceID: V4TraceID(rawValue: request.traceID),
            lane: .selectionRewrite,
            goalSummary: request.command.trimmingCharacters(in: .whitespacesAndNewlines),
            inputText: request.command,
            appName: request.focusContext.appName,
            bundleID: request.focusContext.bundleID,
            selectionText: request.selectionSnapshot?.selectedText,
            enabledFeatureIDs: Set(request.enabledFeatures.map(\.rawValue))
        )

        let outcome = try await loopEngine.run(
            request: v4Request,
            onEvent: { event in
                guard let onEvent else {
                    return
                }
                onEvent(Self.magicianEvent(from: event))
            }
        )

        switch outcome.status {
        case .completed:
            return Self.magicianOutcome(from: outcome)

        case .waitingForUser:
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: outcome.finalStatusMessage,
                debugMessage: outcome.failureCode?.rawValue,
                recoverAction: "retry_command"
            )

        case .failed, .cancelled:
            throw MagicianError(
                code: Self.magicianErrorCode(from: outcome.failureCode),
                userMessage: outcome.finalStatusMessage,
                debugMessage: outcome.failureCode?.rawValue,
                recoverAction: "retry_command"
            )

        case .queued, .planning, .executing, .retrying, .waitingForTool, .verifying:
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "V4 loop 未正常结束。",
                debugMessage: "unexpected outcome status \(outcome.status.rawValue)",
                recoverAction: "retry_command"
            )
        }
    }

    nonisolated private static func magicianOutcome(from outcome: V4RunOutcome) -> MagicianAgentRunOutcome {
        MagicianAgentRunOutcome(
            sessionID: outcome.sessionID.rawValue,
            runID: outcome.runID.rawValue,
            goalSummary: outcome.goalSummary,
            finalStatusMessage: outcome.finalStatusMessage,
            finalOutputText: outcome.finalOutputText,
            displayText: outcome.displayText,
            steps: outcome.stepRecords.map(Self.magicianStepRecord),
            evidenceSummary: outcome.evidenceSummary.isEmpty ? nil : outcome.evidenceSummary
        )
    }

    nonisolated private static func magicianStepRecord(from step: V4StepRecord) -> MagicianAgentStepRecord {
        let observation = MagicianAgentObservation(
            verificationStatus: Self.verificationStatus(for: step),
            targetSummary: step.title,
            evidenceSummary: step.evidenceSummary.isEmpty ? step.outputSummary : step.evidenceSummary,
            autoRepairApplied: step.attemptCount > 1
        )
        return MagicianAgentStepRecord(
            id: step.id.rawValue,
            featureID: Self.featureID(for: step.toolName),
            instruction: step.title,
            userMessage: step.outputSummary ?? step.title,
            outputText: step.outputSummary,
            observation: observation
        )
    }

    nonisolated private static func magicianEvent(from event: V4RuntimeEvent) -> MagicianAgentRuntimeEvent {
        let name: MagicianAgentRuntimeEventName
        switch event.name {
        case .requestAccepted:
            name = .requestAccepted
        case .stateChanged, .stepRetryScheduled:
            name = .stateChanged
        case .planReady:
            name = .planReady
        case .stepStarted:
            name = .stepStarted
        case .stepFinished:
            name = .stepFinished
        case .toolRequested, .toolFinished, .verificationFinished:
            if event.status == .waitingForUser {
                name = .minimalQuestionRaised
            } else if event.name == .verificationFinished, event.status != .failed {
                name = .verificationPassed
            } else {
                name = .stateChanged
            }
        case .runNeedsUserInput:
            name = .minimalQuestionRaised
        case .runCompleted:
            name = .runCompleted
        case .runFailed:
            name = .runFailed
        }

        return MagicianAgentRuntimeEvent(
            name: name,
            state: Self.magicianState(from: event.status),
            message: event.message,
            progressHint: event.progressHint,
            stepIndex: event.stepIndex,
            totalSteps: event.totalSteps
        )
    }

    nonisolated private static func magicianState(from status: V4RunStatus) -> MagicianAgentRuntimeState {
        switch status {
        case .queued:
            return .queued
        case .planning:
            return .planning
        case .executing, .waitingForTool:
            return .executingStep
        case .retrying:
            return .retryingStep
        case .waitingForUser:
            return .waitingForUser
        case .verifying:
            return .verifying
        case .completed:
            return .completed
        case .failed, .cancelled:
            return .failed
        }
    }

    nonisolated private static func verificationStatus(for step: V4StepRecord) -> MagicianAgentVerificationStatus {
        switch step.status {
        case .completed:
            return .verified
        case .waitingForUser:
            return .needsUserInput
        case .failed:
            return .unverified
        default:
            return .assumed
        }
    }

    nonisolated private static func featureID(for toolName: String?) -> MagicianFeatureID {
        switch toolName {
        case "apple.calendar.create":
            return .createEvent
        case "apple.notes.create":
            return .createNote
        case "apple.mail.compose":
            return .composeEmailDraft
        case "apple.music.control":
            return .controlMusic
        case "feishu.cli":
            return .feishuCLI
        case "text.transform", .none:
            return .textTransform
        default:
            return .textTransform
        }
    }

    nonisolated private static func magicianErrorCode(from failureCode: V4FailureCode?) -> MagicianErrorCode {
        switch failureCode {
        case .some(.permissionDenied):
            return .permissionDenied
        case .some(.toolValidationFailed), .some(.invalidRequest):
            return .intentParseFailed
        case .some(.toolExecutionFailed), .some(.maxTurnsExceeded), .some(.verificationFailed):
            return .toolExecutionFailed
        case .some(.bridgeNotReady),
             .some(.historyWriteFailed),
             .some(.modelUnavailable),
             .some(.userCancelled),
             .some(.none),
             .some(.unknown),
             nil:
            return .toolExecutionFailed
        }
    }
}

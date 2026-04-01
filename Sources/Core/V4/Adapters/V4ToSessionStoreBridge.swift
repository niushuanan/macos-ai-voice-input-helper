import Foundation

@MainActor
final class V4ToSessionStoreBridge {
    func applyRunStart(
        request: V4RunRequest,
        to sessionStore: SessionStore
    ) {
        let label = request.goalSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionStore.markRewriting(
            actionLabel: label.isEmpty ? "准备执行" : label,
            stage: .toolAction,
            progressHint: SessionHUDProgressHint.workflowPreview
        )
    }

    func applyRuntimeEvent(
        _ event: V4RuntimeEvent,
        to sessionStore: SessionStore
    ) {
        switch event.status {
        case .queued, .planning, .executing, .retrying, .waitingForTool, .verifying:
            sessionStore.markRewriting(
                actionLabel: event.message,
                stage: .toolAction,
                progressHint: event.progressHint
            )
        case .waitingForUser, .failed, .cancelled:
            sessionStore.fail(message: event.message)
        case .completed:
            break
        }
    }

    func applyRunOutcome(
        _ outcome: V4RunOutcome,
        to sessionStore: SessionStore
    ) {
        switch outcome.status {
        case .completed:
            sessionStore.completeAction(statusMessage: outcome.finalStatusMessage)
        case .waitingForUser, .failed, .cancelled:
            sessionStore.fail(message: outcome.finalStatusMessage)
        case .queued, .planning, .executing, .retrying, .waitingForTool, .verifying:
            sessionStore.markRewriting(
                actionLabel: outcome.finalStatusMessage,
                stage: .toolAction,
                progressHint: SessionHUDProgressHint.workflowPreview
            )
        }
    }
}

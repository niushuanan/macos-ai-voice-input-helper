import Foundation

struct V4ToHistoryBridge {
    func makeHistoryEntry(
        from request: V4RunRequest,
        outcome: V4RunOutcome,
        status: SessionHistoryStatus
    ) -> SessionHistoryEntry? {
        // TODO(Window 05): 把 `traceID/runID/goalSummary/stepRecords/evidenceSummary`
        // 映到 `magicianRunID/magicianGoalSummary/magicianStepSummaries/magicianEvidenceSummary/magicianExecutionTrace`。
        // TODO(Window 06): 把 native fast lane 的 `finalOutputText/lane/appName/bundleID`
        // 映到 `outputText/mode/appName/bundleID`，并补齐 writeback 结果。
        _ = request
        _ = outcome
        _ = status
        return nil
    }
}

import Foundation

struct V4ToHistoryBridge {
    func makeHistoryEntry(
        from request: V4RunRequest,
        outcome: V4RunOutcome,
        status: SessionHistoryStatus,
        focusContext: FocusedAppContext,
        selectionText: String,
        transcription: SpeechTranscriptionResult,
        audioDurationSeconds: Double,
        appliedSkills: [SkillRuleID],
        runtimeEvents: [V4RuntimeEvent]
    ) -> SessionHistoryEntry {
        SessionHistoryEntry(
            timestamp: request.requestedAt,
            mode: .selectionRewrite,
            appName: request.appName ?? focusContext.appName,
            bundleID: request.bundleID ?? focusContext.bundleID,
            inputText: selectionText,
            outputText: outcome.finalOutputText,
            instructionText: request.inputText,
            magicianFeatureID: featureID(from: outcome.stepRecords.last),
            displayText: outcome.displayText,
            transcriptionProvider: transcription.providerName,
            transcriptionModel: transcription.modelName,
            magicianRuntimeVersion: 4,
            magicianSessionID: outcome.sessionID.rawValue,
            magicianRunID: outcome.runID.rawValue,
            magicianGoalSummary: outcome.goalSummary,
            magicianStepSummaries: stepSummaries(from: outcome.stepRecords),
            magicianEvidenceSummary: normalize(outcome.evidenceSummary),
            magicianExecutionTrace: executionTrace(
                request: request,
                outcome: outcome,
                status: status,
                runtimeEvents: runtimeEvents
            ),
            status: status,
            errorMessage: status == .success ? nil : outcome.finalStatusMessage,
            audioDurationSeconds: audioDurationSeconds,
            appliedSkills: appliedSkills
        )
    }

    private func stepSummaries(from stepRecords: [V4StepRecord]) -> [String]? {
        let values = stepRecords.map { step in
            let toolName = step.toolName ?? "text.transform"
            let summary = step.outputSummary ?? step.title
            return "\(toolName):\(summary)"
        }
        return values.isEmpty ? nil : values
    }

    private func featureID(from step: V4StepRecord?) -> MagicianFeatureID? {
        guard let toolName = step?.toolName else {
            return step == nil ? nil : .textTransform
        }

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
        case "text.transform":
            return .textTransform
        default:
            return .textTransform
        }
    }

    private func executionTrace(
        request: V4RunRequest,
        outcome: V4RunOutcome,
        status: SessionHistoryStatus,
        runtimeEvents: [V4RuntimeEvent]
    ) -> String {
        var lines: [String] = []
        lines.append("goal: \(outcome.goalSummary)")
        lines.append("command: \(request.inputText)")
        lines.append("trace_id: \(outcome.traceID.rawValue)")
        lines.append("session_id: \(outcome.sessionID.rawValue)")
        lines.append("run_id: \(outcome.runID.rawValue)")
        lines.append("lane: \(outcome.lane.rawValue)")
        lines.append("status: \(status.rawValue)")
        appendField(&lines, key: "failure_code", value: outcome.failureCode?.rawValue)
        lines.append("")
        appendMemoryInjection(&lines, request: request)

        appendEvents(&lines, runtimeEvents: runtimeEvents)

        if outcome.stepRecords.isEmpty {
            lines.append("steps: (none)")
            lines.append("")
        } else {
            for (index, step) in outcome.stepRecords.enumerated() {
                lines.append("[step \(index + 1)]")
                lines.append("step_id: \(step.id.rawValue)")
                lines.append("title: \(step.title)")
                appendField(&lines, key: "tool", value: step.toolName)
                lines.append("status: \(step.status.rawValue)")
                appendField(&lines, key: "output", value: step.outputSummary)
                appendField(&lines, key: "evidence", value: normalize(step.evidenceSummary))
                appendField(&lines, key: "failure_code", value: step.failureCode?.rawValue)
                lines.append("attempt_count: \(step.attemptCount)")
                lines.append("")
            }
        }

        lines.append("final_status: \(outcome.finalStatusMessage)")
        appendField(&lines, key: "final_output", value: outcome.finalOutputText)
        appendField(&lines, key: "final_evidence", value: normalize(outcome.evidenceSummary))
        return lines.joined(separator: "\n")
    }

    private func appendEvents(
        _ lines: inout [String],
        runtimeEvents: [V4RuntimeEvent]
    ) {
        guard !runtimeEvents.isEmpty else {
            lines.append("events: (none)")
            lines.append("")
            return
        }

        lines.append("events:")
        for (index, event) in runtimeEvents.enumerated() {
            lines.append("  [event \(index + 1)] \(event.name.rawValue) | status=\(event.status.rawValue)")
            appendField(&lines, key: "  message", value: event.message)
            if let stepIndex = event.stepIndex, let totalSteps = event.totalSteps {
                lines.append("  step: \(stepIndex)/\(totalSteps)")
            }
            if let progressHint = event.progressHint {
                lines.append("  progress_hint: \(String(format: "%.3f", progressHint))")
            }
        }
        lines.append("")
    }

    private func appendMemoryInjection(
        _ lines: inout [String],
        request: V4RunRequest
    ) {
        lines.append("memory_injection:")
        lines.append("  hints: \(request.memoryHints.count)")
        lines.append("  related_recent_runs: \(request.relatedRecentRuns.count)")
        lines.append("  conflict_warnings: \(request.conflictWarnings.count)")

        for hint in request.memoryHints.prefix(5) {
            lines.append("  [hint] score=\(String(format: "%.3f", hint.score)) id=\(hint.id)")
            appendField(&lines, key: "    summary", value: hint.summary)
            appendField(&lines, key: "    reason", value: hint.reason)
        }

        for warning in request.conflictWarnings {
            appendField(&lines, key: "  [conflict]", value: warning.message)
            appendField(&lines, key: "    reason", value: warning.reason)
        }

        if request.memoryDebugTrace.isEmpty {
            lines.append("  debug: (none)")
        } else {
            for note in request.memoryDebugTrace {
                lines.append("  debug: \(note)")
            }
        }
        lines.append("")
    }

    private func appendField(
        _ lines: inout [String],
        key: String,
        value: String?
    ) {
        guard let value = normalize(value) else {
            return
        }
        lines.append("\(key): \(value)")
    }

    private func normalize(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

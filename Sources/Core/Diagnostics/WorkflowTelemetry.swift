import Foundation

enum WorkflowTelemetryEventName: String {
    case planSuccess = "workflow.plan.success"
    case planFailed = "workflow.plan.failed"
    case stepSuccess = "workflow.step.success"
    case stepFailed = "workflow.step.failed"
    case done = "workflow.done"
    case failed = "workflow.failed"
}

struct WorkflowTelemetryEvent {
    let traceID: String
    let lane: InputLane
    let provider: String?
    let model: String?
    let event: WorkflowTelemetryEventName
    let errorType: String?
    let detail: String?
    let audioDuration: Double?
    let transcriptLength: Int?
    let workflowVersion: Int?
    let stepCount: Int?
    let stepIndex: Int?
    let stepID: String?
    let feature: String?
    let confidence: Double?
    let durationMs: Int?
    let attempt: Int?
    let autoSendConfigured: Bool?
    let autoSendHit: Bool?
    let draftOnlyFallback: Bool?

    init(
        traceID: String,
        lane: InputLane,
        provider: String?,
        model: String?,
        event: WorkflowTelemetryEventName,
        errorType: String? = nil,
        detail: String? = nil,
        audioDuration: Double? = nil,
        transcriptLength: Int? = nil,
        workflowVersion: Int? = nil,
        stepCount: Int? = nil,
        stepIndex: Int? = nil,
        stepID: String? = nil,
        feature: String? = nil,
        confidence: Double? = nil,
        durationMs: Int? = nil,
        attempt: Int? = nil,
        autoSendConfigured: Bool? = nil,
        autoSendHit: Bool? = nil,
        draftOnlyFallback: Bool? = nil
    ) {
        self.traceID = traceID
        self.lane = lane
        self.provider = provider
        self.model = model
        self.event = event
        self.errorType = errorType
        self.detail = detail
        self.audioDuration = audioDuration
        self.transcriptLength = transcriptLength
        self.workflowVersion = workflowVersion
        self.stepCount = stepCount
        self.stepIndex = stepIndex
        self.stepID = stepID
        self.feature = feature
        self.confidence = confidence
        self.durationMs = durationMs
        self.attempt = attempt
        self.autoSendConfigured = autoSendConfigured
        self.autoSendHit = autoSendHit
        self.draftOnlyFallback = draftOnlyFallback
    }
}

protocol WorkflowTelemetryReporting {
    func record(_ event: WorkflowTelemetryEvent)
}

private struct WorkflowTelemetryLogLine: Encodable {
    let timestamp: String
    let namespace: String
    let traceID: String
    let lane: String
    let provider: String?
    let model: String?
    let event: String
    let errorType: String?
    let detail: String?
    let audioDuration: Double?
    let transcriptLength: Int?
    let workflowVersion: Int?
    let stepCount: Int?
    let stepIndex: Int?
    let stepID: String?
    let feature: String?
    let confidence: Double?
    let durationMs: Int?
    let attempt: Int?
    let autoSendConfigured: Bool?
    let autoSendHit: Bool?
    let draftOnlyFallback: Bool?
}

final class WorkflowTelemetryReporter: WorkflowTelemetryReporting {
    private let speechPipelineLogger: SpeechPipelineLogger?
    private let fileURL: URL?
    private let fileManager: FileManager
    private let jsonEncoder: JSONEncoder

    init(
        diagnosticsDirectory: URL? = nil,
        speechPipelineLogger: SpeechPipelineLogger? = nil,
        fileManager: FileManager = .default
    ) {
        self.speechPipelineLogger = speechPipelineLogger
        self.fileManager = fileManager
        self.fileURL = diagnosticsDirectory?.appendingPathComponent("telemetry.log", isDirectory: false)
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.outputFormatting = [.sortedKeys]
    }

    func record(_ event: WorkflowTelemetryEvent) {
        speechPipelineLogger?.log(
            traceID: event.traceID,
            lane: event.lane,
            provider: event.provider,
            model: event.model,
            httpStatus: nil,
            stage: event.event.rawValue,
            errorType: event.errorType,
            detail: pipelineDetail(for: event),
            audioDuration: event.audioDuration,
            transcriptLength: event.transcriptLength
        )

        guard let fileURL else {
            return
        }

        let line = WorkflowTelemetryLogLine(
            timestamp: Self.timestampFormatter.string(from: Date()),
            namespace: "workflow",
            traceID: event.traceID,
            lane: event.lane.rawValue,
            provider: event.provider,
            model: event.model,
            event: event.event.rawValue,
            errorType: event.errorType,
            detail: Self.redactSensitiveText(event.detail),
            audioDuration: event.audioDuration,
            transcriptLength: event.transcriptLength,
            workflowVersion: event.workflowVersion,
            stepCount: event.stepCount,
            stepIndex: event.stepIndex,
            stepID: event.stepID,
            feature: event.feature,
            confidence: event.confidence,
            durationMs: event.durationMs,
            attempt: event.attempt,
            autoSendConfigured: event.autoSendConfigured,
            autoSendHit: event.autoSendHit,
            draftOnlyFallback: event.draftOnlyFallback
        )

        guard
            let data = try? jsonEncoder.encode(line),
            var text = String(data: data, encoding: .utf8)
        else {
            return
        }
        text.append("\n")
        append(text, to: fileURL)
    }

    private func pipelineDetail(for event: WorkflowTelemetryEvent) -> String? {
        var parts: [String] = []
        if let detail = event.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            parts.append(detail)
        }
        if let durationMs = event.durationMs {
            parts.append("duration_ms=\(durationMs)")
        }
        if let stepCount = event.stepCount {
            parts.append("step_count=\(stepCount)")
        }
        if let stepIndex = event.stepIndex {
            parts.append("step_index=\(stepIndex)")
        }
        if let feature = event.feature {
            parts.append("feature=\(feature)")
        }
        if let attempt = event.attempt {
            parts.append("attempt=\(attempt)")
        }
        if let autoSendConfigured = event.autoSendConfigured {
            parts.append("auto_send_configured=\(autoSendConfigured)")
        }
        if let autoSendHit = event.autoSendHit {
            parts.append("auto_send_hit=\(autoSendHit)")
        }
        if let draftOnlyFallback = event.draftOnlyFallback {
            parts.append("draft_only_fallback=\(draftOnlyFallback)")
        }
        if parts.isEmpty {
            return nil
        }
        return parts.joined(separator: ",")
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func redactSensitiveText(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        var output = text
        output = replaceRegex(
            pattern: #"(?i)(Authorization\s*:\s*Bearer\s+)[A-Za-z0-9._\-]+"#,
            template: "$1[REDACTED]",
            in: output
        )
        output = replaceRegex(
            pattern: #"\bBearer\s+[A-Za-z0-9._\-]{20,}\b"#,
            template: "Bearer [REDACTED]",
            in: output
        )
        output = replaceRegex(
            pattern: #"\bsk-[A-Za-z0-9]{10,}\b"#,
            template: "sk-[REDACTED]",
            in: output
        )
        return output
    }

    private static func replaceRegex(
        pattern: String,
        template: String,
        in text: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    private func append(_ value: String, to url: URL) {
        let data = Data(value.utf8)
        if !fileManager.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

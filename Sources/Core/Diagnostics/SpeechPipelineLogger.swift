import Foundation

private struct SpeechPipelineLogLine: Encodable {
    let timestamp: String
    let traceID: String
    let lane: String
    let provider: String?
    let model: String?
    let httpStatus: Int?
    let stage: String
    let errorType: String?
    let detail: String?
    let audioDuration: Double?
    let transcriptLength: Int?
    let tokenBudget: Int?
}

final class SpeechPipelineLogger {
    private let fileURL: URL
    private let fileManager: FileManager
    private let jsonEncoder: JSONEncoder

    init(
        diagnosticsDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = diagnosticsDirectory.appendingPathComponent(
            "speech-pipeline.log",
            isDirectory: false
        )
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.outputFormatting = [.sortedKeys]
    }

    func log(
        traceID: String,
        lane: InputLane,
        provider: String?,
        model: String?,
        httpStatus: Int?,
        stage: String,
        errorType: String? = nil,
        detail: String? = nil,
        audioDuration: Double? = nil,
        transcriptLength: Int? = nil,
        tokenBudget: Int? = nil
    ) {
        let line = SpeechPipelineLogLine(
            timestamp: Self.timestampFormatter.string(from: Date()),
            traceID: traceID,
            lane: lane.rawValue,
            provider: provider,
            model: model,
            httpStatus: httpStatus,
            stage: stage,
            errorType: errorType,
            detail: Self.redactSensitiveText(detail),
            audioDuration: audioDuration,
            transcriptLength: transcriptLength,
            tokenBudget: tokenBudget
        )

        guard
            let data = try? jsonEncoder.encode(line),
            var text = String(data: data, encoding: .utf8)
        else {
            return
        }
        text.append("\n")
        append(text)
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

    private func append(_ value: String) {
        let data = Data(value.utf8)
        if !fileManager.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

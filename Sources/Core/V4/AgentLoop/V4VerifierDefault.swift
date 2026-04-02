import Foundation

struct V4VerifierDefault: V4Verifier {
    func verify(
        for request: V4RunRequest,
        stepRecords: [V4StepRecord],
        latestToolResult: V4ToolResult?
    ) async -> V4VerificationResult {
        let mergedEvidence = mergedEvidenceSummary(
            requestEvidence: request.evidenceSummary,
            stepRecords: stepRecords,
            latestToolResult: latestToolResult
        )

        if let error = latestToolResult?.error {
            let status: V4VerificationStatus = needsUserInput(for: error)
                ? .needsUserInput
                : .failed
            return V4VerificationResult(
                status: status,
                message: error.messageForUser,
                evidenceSummary: mergedEvidence
            )
        }

        if let semantic = semanticVerification(for: latestToolResult, mergedEvidence: mergedEvidence) {
            return semantic
        }

        let message: String
        if let outputText = latestToolResult?.outputText?.trimmingCharacters(in: .whitespacesAndNewlines), !outputText.isEmpty {
            message = "已记录步骤输出并通过默认核验。"
        } else {
            message = "已记录步骤结果并通过默认核验。"
        }
        return V4VerificationResult(
            status: .passed,
            message: message,
            evidenceSummary: mergedEvidence
        )
    }

    private func mergedEvidenceSummary(
        requestEvidence: String,
        stepRecords: [V4StepRecord],
        latestToolResult: V4ToolResult?
    ) -> String {
        var evidenceLines = [String]()
        if !requestEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            evidenceLines.append(requestEvidence.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        evidenceLines.append(
            contentsOf: stepRecords.compactMap {
                let value = $0.evidenceSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        )
        if let latestToolResult {
            let latestEvidence = latestToolResult.evidenceSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !latestEvidence.isEmpty {
                evidenceLines.append(latestEvidence)
            }
        }

        var deduped = [String]()
        var seen = Set<String>()
        for line in evidenceLines {
            guard seen.insert(line).inserted else {
                continue
            }
            deduped.append(line)
        }
        return deduped.joined(separator: "\n")
    }

    private func needsUserInput(for error: V4ToolError) -> Bool {
        switch error.code {
        case .permissionDenied, .toolValidationFailed, .invalidRequest:
            return true
        default:
            return false
        }
    }

    private func semanticVerification(
        for latestToolResult: V4ToolResult?,
        mergedEvidence: String
    ) -> V4VerificationResult? {
        guard let latestToolResult else {
            return nil
        }

        switch latestToolResult.toolName {
        case "apple.music.control":
            let fields = parseEvidenceFields(from: latestToolResult.evidenceSummary)
            let action = fields["action"]?.lowercased() ?? ""
            if action == "open" {
                return V4VerificationResult(
                    status: .needsUserInput,
                    message: "Music 仅已打开，尚未执行播放动作。",
                    evidenceSummary: mergedEvidence
                )
            }
            if action == "play" {
                let hasTrackEvidence = latestToolResult.evidenceSummary.lowercased().contains("track=")
                if !hasTrackEvidence {
                    return V4VerificationResult(
                        status: .failed,
                        message: "音乐动作缺少曲目证据，已判定失败。",
                        evidenceSummary: mergedEvidence
                    )
                }
            }
            return nil

        case "apple.notes.create":
            let lowered = latestToolResult.evidenceSummary.lowercased()
            let fields = parseEvidenceFields(from: latestToolResult.evidenceSummary)
            let action = (fields["action"] ?? "create").lowercased()
            switch action {
            case "find":
                let hasMatched = fields["matched"] != nil || lowered.contains("matched=")
                if !hasMatched {
                    return V4VerificationResult(
                        status: .failed,
                        message: "备忘录检索缺少命中证据，已判定失败。",
                        evidenceSummary: mergedEvidence
                    )
                }
            default:
                let hasNoteEvidence = lowered.contains("note_id=") || lowered.contains("x-coredata://")
                if !hasNoteEvidence {
                    return V4VerificationResult(
                        status: .failed,
                        message: "备忘录动作缺少结构化证据，已判定失败。",
                        evidenceSummary: mergedEvidence
                    )
                }
            }
            return nil

        case "apple.mail.compose":
            let payload = parseRawPayloadObject(from: latestToolResult.rawPayload)
            let verificationStatus = (payload["verificationStatus"] as? String)?.lowercased()
            if verificationStatus == "assumed" || verificationStatus == "unverified" {
                return V4VerificationResult(
                    status: .needsUserInput,
                    message: "邮件动作仅完成窗口级别，请确认邮件后再继续。",
                    evidenceSummary: mergedEvidence
                )
            }
            return nil

        default:
            return nil
        }
    }

    private func parseEvidenceFields(from evidenceSummary: String) -> [String: String] {
        evidenceSummary
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reduce(into: [String: String]()) { partialResult, item in
                let keyValue = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard keyValue.count == 2 else {
                    return
                }
                let key = String(keyValue[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(keyValue[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else {
                    return
                }
                partialResult[key] = value
            }
    }

    private func parseRawPayloadObject(from rawPayload: String?) -> [String: Any] {
        guard
            let rawPayload,
            let data = rawPayload.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data),
            let object = json as? [String: Any]
        else {
            return [:]
        }
        return object
    }
}

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
                message: error.userMessage,
                evidenceSummary: mergedEvidence
            )
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
        switch error.failureCode {
        case .permissionDenied, .toolValidationFailed, .invalidRequest:
            return true
        default:
            return false
        }
    }
}

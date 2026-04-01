import Foundation

struct V4ToolEvidencePolicy: Sendable {
    func validate(
        output: V4ToolExecutionOutput,
        manifest: V4ToolManifest,
        toolID: String,
        errorCatalog: V4ToolErrorCatalog
    ) -> V4ToolError? {
        switch manifest.evidenceRequirement.level {
        case .none:
            return nil

        case .summary:
            guard !output.evidenceSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return errorCatalog.missingEvidence(
                    toolID: toolID,
                    requirement: manifest.evidenceRequirement,
                    debugMessage: "evidence summary missing for \(toolID)"
                )
            }
            return nil

        case .structured:
            guard !output.evidenceSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return errorCatalog.missingEvidence(
                    toolID: toolID,
                    requirement: manifest.evidenceRequirement,
                    debugMessage: "structured evidence summary missing for \(toolID)"
                )
            }
            guard let object = output.rawPayload?.objectValue else {
                return errorCatalog.missingEvidence(
                    toolID: toolID,
                    requirement: manifest.evidenceRequirement,
                    debugMessage: "structured raw payload missing for \(toolID)"
                )
            }
            let missingKeys = manifest.evidenceRequirement.requiredKeys.filter {
                guard let value = object[$0] else {
                    return true
                }
                switch value {
                case let .string(text):
                    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .null:
                    return true
                default:
                    return false
                }
            }
            guard missingKeys.isEmpty else {
                return errorCatalog.missingEvidence(
                    toolID: toolID,
                    requirement: manifest.evidenceRequirement,
                    debugMessage: "structured evidence keys missing for \(toolID): \(missingKeys.joined(separator: ","))"
                )
            }
            return nil
        }
    }
}

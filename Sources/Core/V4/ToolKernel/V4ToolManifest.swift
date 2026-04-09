import Foundation

enum V4ToolEvidenceRequirementLevel: String, Codable, Equatable, Sendable {
    case none
    case summary
    case structured
}

struct V4ToolEvidenceRequirement: Codable, Equatable, Sendable {
    let level: V4ToolEvidenceRequirementLevel
    let requiredKeys: [String]

    init(
        level: V4ToolEvidenceRequirementLevel,
        requiredKeys: [String] = []
    ) {
        self.level = level
        self.requiredKeys = requiredKeys
    }

    static let none = V4ToolEvidenceRequirement(level: .none)
    static let summary = V4ToolEvidenceRequirement(level: .summary)

    static func structured(requiredKeys: [String]) -> V4ToolEvidenceRequirement {
        V4ToolEvidenceRequirement(level: .structured, requiredKeys: requiredKeys)
    }
}

struct V4ToolManifest: Codable, Equatable, Sendable, Identifiable {
    let toolID: String
    let displayName: String
    let domain: String
    let requiredFeature: MagicianFeatureID?
    let inputSchemaSummary: String
    let isConcurrencySafe: Bool
    let supportsRetry: Bool
    let evidenceRequirement: V4ToolEvidenceRequirement
    let retryPolicy: V4ToolRetryPolicy
    let keywords: [String]

    var id: String { toolID }

    init(
        toolID: String,
        displayName: String,
        domain: String,
        requiredFeature: MagicianFeatureID?,
        inputSchemaSummary: String,
        isConcurrencySafe: Bool,
        retryPolicy: V4ToolRetryPolicy,
        evidenceRequirement: V4ToolEvidenceRequirement,
        keywords: [String] = []
    ) {
        self.toolID = toolID
        self.displayName = displayName
        self.domain = domain
        self.requiredFeature = requiredFeature
        self.inputSchemaSummary = inputSchemaSummary
        self.isConcurrencySafe = isConcurrencySafe
        self.retryPolicy = retryPolicy
        self.supportsRetry = retryPolicy.supportsRetry
        self.evidenceRequirement = evidenceRequirement
        self.keywords = keywords
    }

    func matches(keyword: String) -> Bool {
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedKeyword.isEmpty else {
            return true
        }

        return searchableFields.contains { field in
            field.localizedCaseInsensitiveContains(normalizedKeyword)
        }
    }

    private var searchableFields: [String] {
        [
            toolID,
            displayName,
            domain,
            requiredFeature?.rawValue ?? "none",
            requiredFeature?.displayName ?? "none",
            inputSchemaSummary
        ] + keywords
    }
}

extension V4ToolManifest {
    static func derived(
        from spec: V4ToolSpec,
        domain: String? = nil,
        retryPolicy: V4ToolRetryPolicy = .none,
        evidenceRequirement: V4ToolEvidenceRequirement = .summary,
        keywords: [String] = []
    ) -> V4ToolManifest {
        let summary = spec.inputSchema.fields.map {
            let required = $0.isRequired ? "必填" : "可选"
            return "\($0.name)(\($0.kind.rawValue), \(required))"
        }.joined(separator: ", ")
        let resolvedDomain = domain ?? spec.toolName.components(separatedBy: ".").first ?? "general"
        return V4ToolManifest(
            toolID: spec.toolName,
            displayName: spec.displayName,
            domain: resolvedDomain,
            requiredFeature: spec.requiredFeature,
            inputSchemaSummary: summary.isEmpty ? "无输入" : summary,
            isConcurrencySafe: spec.isConcurrencySafe,
            retryPolicy: retryPolicy,
            evidenceRequirement: evidenceRequirement,
            keywords: keywords
        )
    }
}

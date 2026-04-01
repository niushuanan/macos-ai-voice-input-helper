import Foundation

final class V4PromptStackResolver: @unchecked Sendable {
    private let providers: [V4PromptLayerProvider]

    init(providers: [V4PromptLayerProvider] = V4PromptLayerProviders.live()) {
        self.providers = providers
    }

    func resolve(for request: V4RunRequest) async -> V4PromptStack {
        await resolve(context: V4PromptContext(request: request))
    }

    func resolve(context: V4PromptContext) async -> V4PromptStack {
        let orderedProviders = providers.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }

        var layers: [V4PromptLayer] = []
        var mergedGuidance: [String: String] = [:]
        var mergedConstraints: [String: String] = [:]
        var finalUserPrompt = ""
        var appliedSkillRuleIDs: [SkillRuleID] = []
        var systemSegments: [String] = []

        for provider in orderedProviders {
            guard let layer = await provider.makeLayer(for: context), layer.hasContent else {
                continue
            }
            layers.append(layer)

            if let systemPrompt = normalized(layer.systemPrompt) {
                systemSegments.append("[\(layer.name.rawValue)]\n\(systemPrompt)")
            }

            for key in layer.guidance.keys.sorted() {
                if let value = normalized(layer.guidance[key]) {
                    mergedGuidance[key] = value
                }
            }

            for key in layer.constraints.keys.sorted() {
                if let value = normalized(layer.constraints[key]) {
                    mergedConstraints[key] = value
                }
            }

            if let userPrompt = normalized(layer.userPrompt) {
                finalUserPrompt = userPrompt
            }

            switch layer.name {
            case .nowYouSeeMe:
                if layer.guidance["inputCleaning"] != nil {
                    appendUnique(.spokenFilter, to: &appliedSkillRuleIDs)
                }
                if normalized(layer.systemPrompt) != nil {
                    appendUnique(.systemPrompt, to: &appliedSkillRuleIDs)
                }
            case .appScene:
                appendUnique(.appPreferenceBoost, to: &appliedSkillRuleIDs)
            case .global, .lane, .task:
                break
            }
        }

        return V4PromptStack(
            context: context,
            appliedLayers: layers,
            finalSystemPrompt: systemSegments.joined(separator: "\n\n"),
            finalGuidancePrompt: renderGuidance(guidance: mergedGuidance, constraints: mergedConstraints),
            finalUserPrompt: finalUserPrompt,
            guidance: mergedGuidance,
            constraints: mergedConstraints,
            appliedSkillRuleIDs: appliedSkillRuleIDs,
            createdAt: Date()
        )
    }

    private func renderGuidance(
        guidance: [String: String],
        constraints: [String: String]
    ) -> String {
        var sections: [String] = []

        if !guidance.isEmpty {
            let lines = guidance.keys.sorted().compactMap { key -> String? in
                guard let value = guidance[key] else {
                    return nil
                }
                return "- \(key): \(value)"
            }
            if !lines.isEmpty {
                sections.append("[Guidance]\n" + lines.joined(separator: "\n"))
            }
        }

        if !constraints.isEmpty {
            let lines = constraints.keys.sorted().compactMap { key -> String? in
                guard let value = constraints[key] else {
                    return nil
                }
                return "- \(key): \(value)"
            }
            if !lines.isEmpty {
                sections.append("[Constraints]\n" + lines.joined(separator: "\n"))
            }
        }

        return sections.joined(separator: "\n\n")
    }

    private func appendUnique(_ ruleID: SkillRuleID, to values: inout [SkillRuleID]) {
        if !values.contains(ruleID) {
            values.append(ruleID)
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}


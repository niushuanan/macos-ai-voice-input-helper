import Foundation

struct V4NowYouSeeMeSnapshot: Equatable, Sendable {
    let spokenFilterTokens: [String]
    let isAppPreferenceBoostEnabled: Bool
    let systemPrompt: String?

    var injectedSkillRuleIDs: [SkillRuleID] {
        var result: [SkillRuleID] = []
        if !spokenFilterTokens.isEmpty {
            result.append(.spokenFilter)
        }
        if let systemPrompt, !systemPrompt.isEmpty {
            result.append(.systemPrompt)
        }
        return result
    }
}

@MainActor
final class V4SkillRuleBridge {
    private let skillRuleStore: SkillRuleStore

    init(skillRuleStore: SkillRuleStore) {
        self.skillRuleStore = skillRuleStore
    }

    func snapshot() -> V4NowYouSeeMeSnapshot {
        let spokenRule = skillRuleStore.rule(for: .spokenFilter)
        let systemRule = skillRuleStore.rule(for: .systemPrompt)

        let spokenFilterTokens: [String]
        if spokenRule.isEnabled {
            spokenFilterTokens = spokenRule.parameter
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            spokenFilterTokens = []
        }

        let systemPrompt = systemRule.isEnabled
            ? systemRule.parameter.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            : nil

        return V4NowYouSeeMeSnapshot(
            spokenFilterTokens: spokenFilterTokens,
            isAppPreferenceBoostEnabled: skillRuleStore.isEnabled(.appPreferenceBoost),
            systemPrompt: systemPrompt
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}


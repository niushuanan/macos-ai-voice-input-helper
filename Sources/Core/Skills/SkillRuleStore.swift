import Foundation

enum SkillRuleID: String, CaseIterable, Codable, Identifiable {
    case autoPolish
    case spokenFilter
    case autoStructure
    case appPreferenceBoost
    case systemPrompt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoPolish:
            return "自动润色"
        case .spokenFilter:
            return "口语过滤"
        case .autoStructure:
            return "自动结构化"
        case .appPreferenceBoost:
            return "按应用偏好增强"
        case .systemPrompt:
            return "系统提示词"
        }
    }

    var subtitle: String {
        switch self {
        case .autoPolish:
            return "自动整理空格和常见标点。"
        case .spokenFilter:
            return "过滤口头语，默认词表可编辑。"
        case .autoStructure:
            return "把长句整理成清晰分点。"
        case .appPreferenceBoost:
            return "读取“场景策略”并按当前应用风格做微调。"
        case .systemPrompt:
            return "每次文本处理都会附加这段提示。"
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .autoPolish:
            return true
        case .spokenFilter:
            return false
        case .autoStructure:
            return false
        case .appPreferenceBoost:
            return true
        case .systemPrompt:
            return true
        }
    }

    var defaultParameter: String {
        switch self {
        case .autoPolish:
            return "标准"
        case .spokenFilter:
            return "嗯,啊,就是,那个,然后"
        case .autoStructure:
            return "要点列表"
        case .appPreferenceBoost:
            return "自动"
        case .systemPrompt:
            return ""
        }
    }
}

struct SkillRule: Identifiable, Codable, Equatable {
    let id: SkillRuleID
    var isEnabled: Bool
    var parameter: String

    static func defaults() -> [SkillRule] {
        SkillRuleID.allCases.map {
            SkillRule(
                id: $0,
                isEnabled: $0.defaultEnabled,
                parameter: $0.defaultParameter
            )
        }
    }
}

struct SkillApplyResult: Equatable {
    let text: String
    let appliedSkills: [SkillRuleID]

    static let empty = SkillApplyResult(text: "", appliedSkills: [])
}

@MainActor
final class SkillRuleStore: ObservableObject {
    @Published private(set) var rules: [SkillRule]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "skill.rules.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey

        if
            let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([SkillRule].self, from: data)
        {
            self.rules = Self.mergeWithDefaults(decoded)
        } else {
            self.rules = SkillRule.defaults()
            persist()
        }
    }

    func rule(for id: SkillRuleID) -> SkillRule {
        rules.first(where: { $0.id == id }) ?? SkillRule(id: id, isEnabled: id.defaultEnabled, parameter: id.defaultParameter)
    }

    func setEnabled(_ enabled: Bool, for id: SkillRuleID) {
        updateRule(for: id) { rule in
            rule.isEnabled = enabled
        }
    }

    func setParameter(_ parameter: String, for id: SkillRuleID) {
        updateRule(for: id) { rule in
            rule.parameter = parameter
        }
    }

    func applyDictation(_ text: String, outputBias: AppOutputBias) -> SkillApplyResult {
        applyPipeline(
            text,
            outputBias: outputBias,
            allowSpokenFilter: true,
            allowStructure: true
        )
    }

    func applyRewriteInstruction(_ instruction: String) -> SkillApplyResult {
        applyPipeline(
            instruction,
            outputBias: .neutral,
            allowSpokenFilter: true,
            allowStructure: false
        )
    }

    func applyRewriteOutput(_ text: String, outputBias: AppOutputBias) -> SkillApplyResult {
        applyPipeline(
            text,
            outputBias: outputBias,
            allowSpokenFilter: false,
            allowStructure: true
        )
    }

    func activeSystemPrompt() -> String? {
        let rule = rule(for: .systemPrompt)
        guard rule.isEnabled else {
            return nil
        }

        let prompt = rule.parameter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return nil
        }
        return prompt
    }

    private func applyPipeline(
        _ original: String,
        outputBias: AppOutputBias,
        allowSpokenFilter: Bool,
        allowStructure: Bool
    ) -> SkillApplyResult {
        let base = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            return SkillApplyResult(text: original, appliedSkills: [])
        }

        var value = base
        var appliedSkills: [SkillRuleID] = []

        if allowSpokenFilter, rule(for: .spokenFilter).isEnabled {
            let transformed = applySpokenFilter(value, parameter: rule(for: .spokenFilter).parameter)
            if transformed != value {
                appliedSkills.append(.spokenFilter)
            }
            value = transformed
        }

        if rule(for: .autoPolish).isEnabled {
            let transformed = applyAutoPolish(value)
            if transformed != value {
                appliedSkills.append(.autoPolish)
            }
            value = transformed
        }

        if allowStructure, rule(for: .autoStructure).isEnabled {
            let transformed = applyStructureIfNeeded(value)
            if transformed != value {
                appliedSkills.append(.autoStructure)
            }
            value = transformed
        }

        if rule(for: .appPreferenceBoost).isEnabled {
            let transformed = applyAppBias(value, outputBias: outputBias)
            if transformed != value {
                appliedSkills.append(.appPreferenceBoost)
            }
            value = transformed
        }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return SkillApplyResult(text: original, appliedSkills: [])
        }
        return SkillApplyResult(
            text: normalized,
            appliedSkills: appliedSkills
        )
    }

    private func applySpokenFilter(_ text: String, parameter: String) -> String {
        let tokens = parameter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            return text
        }

        var value = text
        for token in tokens {
            value = value.replacingOccurrences(of: token, with: "")
        }
        return value.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
    }

    private func applyAutoPolish(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        value = value.replacingOccurrences(of: " ,", with: ",")
        value = value.replacingOccurrences(of: " .", with: ".")
        value = value.replacingOccurrences(of: " ，", with: "，")
        value = value.replacingOccurrences(of: " 。", with: "。")
        value = value.replacingOccurrences(of: " ？", with: "？")
        value = value.replacingOccurrences(of: " ！", with: "！")

        return value
    }

    private func applyStructureIfNeeded(_ text: String) -> String {
        if text.contains("\n") {
            return text
        }

        let separators = CharacterSet(charactersIn: "。！？!?；;.")
        let lines = text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else {
            return text
        }

        return lines.map { "• \($0)" }.joined(separator: "\n")
    }

    private func applyAppBias(_ text: String, outputBias: AppOutputBias) -> String {
        switch outputBias {
        case .structured:
            return applyStructureIfNeeded(text)
        case .formal:
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasSuffix("。") || value.hasSuffix(".") || value.hasSuffix("！") || value.hasSuffix("？") {
                return value
            }
            return value + "。"
        case .casual, .neutral:
            return text
        }
    }

    private func updateRule(for id: SkillRuleID, mutate: (inout SkillRule) -> Void) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            return
        }
        var rule = rules[index]
        mutate(&rule)
        rules[index] = rule
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private static func mergeWithDefaults(_ decoded: [SkillRule]) -> [SkillRule] {
        let map = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        return SkillRuleID.allCases.map { id in
            map[id] ?? SkillRule(id: id, isEnabled: id.defaultEnabled, parameter: id.defaultParameter)
        }
    }
}

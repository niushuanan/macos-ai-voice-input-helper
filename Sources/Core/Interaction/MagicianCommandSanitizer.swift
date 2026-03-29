import Foundation

enum MagicianCommandSanitizer {
    static func sanitize(_ rawInstruction: String) -> SkillApplyResult {
        let trimmed = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SkillApplyResult(text: "", appliedSkills: [])
        }

        var value = trimmed
        for token in ["左", "右", "上", "下", "前", "后"] {
            value = collapseRepeatedToken(in: value, token: token)
        }
        for word in ["shift", "option", "command", "control", "ctrl"] {
            value = collapseRepeatedWord(in: value, word: word)
        }
        value = value.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return SkillApplyResult(
            text: value.trimmingCharacters(in: .whitespacesAndNewlines),
            appliedSkills: []
        )
    }

    private static func collapseRepeatedToken(in text: String, token: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(\(escaped))\\s*\\1+"
        return replacingMatches(in: text, pattern: pattern, template: "$1")
    }

    private static func collapseRepeatedWord(in text: String, word: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let pattern = "(?i)\\b(\(escaped))\\b(?:\\s+\\1\\b)+"
        return replacingMatches(in: text, pattern: pattern, template: "$1")
    }

    private static func replacingMatches(in text: String, pattern: String, template: String) -> String {
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
}

struct MagicianCommandPreprocessResult: Equatable {
    let command: String
    let appliedSkills: [SkillRuleID]
    let usedModel: Bool
    let notice: String?
}

@MainActor
struct MagicianCommandSemanticPreprocessor {
    let providerSettingsStore: ProviderSettingsStore
    let rewriteProviderRegistry: RewriteProviderRegistry
    let skillRuleStore: SkillRuleStore
    let asrDictionaryStore: ASRDictionaryStore

    func preprocess(
        rawCommand: String,
        focusContext: FocusedAppContext
    ) async -> MagicianCommandPreprocessResult {
        let trimmedRaw = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            return MagicianCommandPreprocessResult(
                command: "",
                appliedSkills: [],
                usedModel: false,
                notice: nil
            )
        }

        let sanitized = MagicianCommandSanitizer.sanitize(trimmedRaw)
        let localApply = skillRuleStore.applyRewriteInstruction(sanitized.text)
        let baseCommand = localApply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var appliedSkills = mergedSkills(sanitized.appliedSkills, localApply.appliedSkills)
        guard !baseCommand.isEmpty else {
            return MagicianCommandPreprocessResult(
                command: trimmedRaw,
                appliedSkills: appliedSkills,
                usedModel: false,
                notice: nil
            )
        }

        guard providerSettingsStore.isCLITextConfigurationValid else {
            return MagicianCommandPreprocessResult(
                command: baseCommand,
                appliedSkills: appliedSkills,
                usedModel: false,
                notice: nil
            )
        }

        let apiKey: String
        do {
            apiKey = try providerSettingsStore.loadAPIKeyForCLIProvider()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return MagicianCommandPreprocessResult(
                command: baseCommand,
                appliedSkills: appliedSkills,
                usedModel: false,
                notice: "命令语义预处理暂不可用，已按原句执行。"
            )
        }
        guard !apiKey.isEmpty else {
            return MagicianCommandPreprocessResult(
                command: baseCommand,
                appliedSkills: appliedSkills,
                usedModel: false,
                notice: nil
            )
        }

        let configuration = providerSettingsStore.cliRewriteConfiguration
        guard let provider = rewriteProviderRegistry.provider(for: configuration.providerType) else {
            return MagicianCommandPreprocessResult(
                command: baseCommand,
                appliedSkills: appliedSkills,
                usedModel: false,
                notice: nil
            )
        }

        let dictionaryTerms = Array(asrDictionaryStore.currentSnapshot().injectedTerms.prefix(40))
        do {
            let rewritten = try await provider.rewrite(
                request: SelectionRewriteRequest(
                    selectedText: baseCommand,
                    spokenInstruction: commandPrompt(dictionaryTerms: dictionaryTerms),
                    focusContext: focusContext,
                    outputBias: .neutral,
                    appPrompt: nil,
                    userSystemPrompt: nil
                ),
                configuration: configuration,
                apiKey: apiKey
            )
            let modelApply = skillRuleStore.applyRewriteInstruction(rewritten.rewrittenText)
            let finalCommand = modelApply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalCommand.isEmpty else {
                return MagicianCommandPreprocessResult(
                    command: baseCommand,
                    appliedSkills: appliedSkills,
                    usedModel: false,
                    notice: nil
                )
            }
            appliedSkills = mergedSkills(appliedSkills, modelApply.appliedSkills)
            return MagicianCommandPreprocessResult(
                command: finalCommand,
                appliedSkills: appliedSkills,
                usedModel: true,
                notice: nil
            )
        } catch {
            return MagicianCommandPreprocessResult(
                command: baseCommand,
                appliedSkills: appliedSkills,
                usedModel: false,
                notice: "命令语义预处理失败，已按原句执行。"
            )
        }
    }

    private func commandPrompt(dictionaryTerms: [String]) -> String {
        let dictionaryLine: String
        if dictionaryTerms.isEmpty {
            dictionaryLine = "词典为空。"
        } else {
            dictionaryLine = "词典词条：\(dictionaryTerms.joined(separator: "、"))。"
        }

        return """
        你是语音命令纠错器。请把用户语音命令改成更可执行、字段更完整的一句话命令。
        要求：
        1) 只输出修正后的命令，不要解释。
        2) 保持用户意图不变，优先修正同音错字、人名、群名、文档名。
        3) 如果命令里已有 URL、ID、token、open_id，必须原样保留。
        4) 命令太短时只补必要词，不要扩写成长段说明。
        5) 不要生成 CLI 参数格式。
        \(dictionaryLine)
        """
    }

    private func mergedSkills(
        _ lhs: [SkillRuleID],
        _ rhs: [SkillRuleID]
    ) -> [SkillRuleID] {
        var merged: [SkillRuleID] = []
        for skill in lhs where !merged.contains(skill) {
            merged.append(skill)
        }
        for skill in rhs where !merged.contains(skill) {
            merged.append(skill)
        }
        return merged
    }
}

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
    private enum Scene {
        case music
        case feishu
        case generic
    }

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
        let scene = inferScene(from: baseCommand)
        do {
            let rewritten = try await provider.rewrite(
                request: SelectionRewriteRequest(
                    selectedText: baseCommand,
                    spokenInstruction: commandPrompt(scene: scene, dictionaryTerms: dictionaryTerms),
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

    private func inferScene(from command: String) -> Scene {
        let lowered = command.lowercased()
        if containsAny(
            lowered,
            keywords: ["音乐", "歌曲", "歌", "播放", "暂停", "继续", "下一首", "上一首", "music", "play", "pause", "next", "previous"]
        ) {
            return .music
        }
        if containsAny(
            lowered,
            keywords: ["飞书", "lark", "消息", "群", "chat", "文档", "wiki", "日程", "calendar", "任务", "多维表格", "bitable", "发给", "通知", "搜索"]
        ) {
            return .feishu
        }
        return .generic
    }

    private func commandPrompt(scene: Scene, dictionaryTerms: [String]) -> String {
        let dictionaryLine: String
        if dictionaryTerms.isEmpty {
            dictionaryLine = "词典为空。"
        } else {
            dictionaryLine = "词典词条：\(dictionaryTerms.joined(separator: "、"))。"
        }

        let scenePrompt: String
        switch scene {
        case .music:
            scenePrompt = """
            场景：音乐命令（Music 应用）。
            用户偏好：用户几乎只点周杰伦的歌；当歌手词不清晰时，优先往“周杰伦”纠正。
            常见口语与错词：
            - “周杰侖、周结伦、粥杰伦” -> “周杰伦”
            - “到香、稻乡” -> “稻香”
            命令目标：播放某歌手/歌曲、暂停、继续、上一首、下一首。
            输出尽量保留一句自然话，不要改成参数格式。
            """
        case .feishu:
            scenePrompt = """
            场景：飞书命令（Feishu/Lark CLI）。
            优先优化到已支持高频场景：
            1) 查/建日程；2) 发消息（找人或群）；3) 查文档/Wiki；
            4) 创建文档；5) 搜索用户；6) 创建多维表格；7) 任务查询/更新。
            对不明确对象（人名、群名、文档名）要先纠错成更像真实名称，方便后续解析唯一目标。
            常见口语与错词：
            - “非书、飞鼠、飞叔” -> “飞书”
            - “拉克、lurk” -> “lark”
            输出保持一句可执行自然话，不要生成 CLI flags。
            """
        case .generic:
            scenePrompt = "场景：通用命令纠错。"
        }

        return """
        你是语音命令纠错器。请把用户语音命令改成更可执行、字段更完整的一句话命令。
        要求：
        1) 只输出修正后的命令，不要解释。
        2) 保持用户意图不变，优先修正同音错字、人名、群名、文档名。
        3) 如果命令里已有 URL、ID、token、open_id，必须原样保留。
        4) 命令太短时只补必要词，不要扩写成长段说明。
        5) 不要生成 CLI 参数格式。
        \(scenePrompt)
        \(dictionaryLine)
        """
    }

    private func containsAny(_ value: String, keywords: [String]) -> Bool {
        keywords.contains { value.contains($0) }
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

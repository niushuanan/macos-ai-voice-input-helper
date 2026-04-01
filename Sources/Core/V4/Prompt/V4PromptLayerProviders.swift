import Foundation

struct V4PromptLayerProvider: @unchecked Sendable {
    let name: V4PromptLayerName
    let priority: Int
    let build: (V4PromptContext) async -> V4PromptLayer?

    func makeLayer(for context: V4PromptContext) async -> V4PromptLayer? {
        await build(context)
    }
}

enum V4PromptLayerProviders {
    static func live(
        skillRuleBridge: V4SkillRuleBridge? = nil,
        appScenePolicyStore: AppScenePolicyStore? = nil
    ) -> [V4PromptLayerProvider] {
        [
            global(),
            nowYouSeeMe(skillRuleBridge: skillRuleBridge),
            appScene(skillRuleBridge: skillRuleBridge, appScenePolicyStore: appScenePolicyStore),
            lane(),
            task()
        ]
    }

    static func global() -> V4PromptLayerProvider {
        V4PromptLayerProvider(name: .global, priority: 0) { _ in
            V4PromptLayer(
                id: V4PromptLayerName.global.rawValue,
                name: .global,
                priority: 0,
                systemPrompt: "你是 PulseType V4 的统一执行管线。优先给出真实、可执行、可追踪的结果，不要虚构工具结果或上下文。",
                guidance: [:],
                constraints: [
                    "runtimeRule": "如果信息不足，只提出最小必要问题；如果已经能执行，就直接继续。"
                ],
                userPrompt: nil,
                sourceSummary: "v4.global.defaults",
                isMutable: false
            )
        }
    }

    static func nowYouSeeMe(skillRuleBridge: V4SkillRuleBridge?) -> V4PromptLayerProvider {
        V4PromptLayerProvider(name: .nowYouSeeMe, priority: 1) { _ in
            guard let skillRuleBridge else {
                return nil
            }
            let snapshot = await skillRuleBridge.snapshot()

            var guidance: [String: String] = [:]
            var constraints: [String: String] = [:]

            if !snapshot.spokenFilterTokens.isEmpty {
                guidance["inputCleaning"] = "输入清洗策略：先过滤这些口头词：\(snapshot.spokenFilterTokens.joined(separator: "、"))。"
                constraints["inputCleaningGuard"] = "只过滤明确命中的口头词，不要顺手改写用户原意。"
            }

            let systemPrompt = snapshot.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)

            let layer = V4PromptLayer(
                id: V4PromptLayerName.nowYouSeeMe.rawValue,
                name: .nowYouSeeMe,
                priority: 1,
                systemPrompt: systemPrompt?.isEmpty == false ? systemPrompt : nil,
                guidance: guidance,
                constraints: constraints,
                userPrompt: nil,
                sourceSummary: "skill.rules.now-you-see-me",
                isMutable: true
            )

            return layer.hasContent ? layer : nil
        }
    }

    static func appScene(
        skillRuleBridge: V4SkillRuleBridge?,
        appScenePolicyStore: AppScenePolicyStore?
    ) -> V4PromptLayerProvider {
        V4PromptLayerProvider(name: .appScene, priority: 2) { context in
            guard
                let skillRuleBridge,
                let appScenePolicyStore
            else {
                return nil
            }

            let snapshot = await skillRuleBridge.snapshot()
            guard snapshot.isAppPreferenceBoostEnabled else {
                return nil
            }

            let appName = context.sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let bundleID = context.sourceBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !appName.isEmpty, !bundleID.isEmpty else {
                return nil
            }

            let policy = await MainActor.run {
                appScenePolicyStore.policy(
                    for: FocusedAppContext(
                        appName: appName,
                        bundleID: bundleID,
                        focusedRole: nil,
                        hasEditableTarget: true,
                        strategyHint: ""
                    )
                )
            }
            let scenePrompt = policy.appPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !scenePrompt.isEmpty else {
                return nil
            }

            let layer = V4PromptLayer(
                id: V4PromptLayerName.appScene.rawValue,
                name: .appScene,
                priority: 2,
                systemPrompt: nil,
                guidance: [
                    "scenePreference": "当前应用：\(appName)（\(bundleID)）。场景偏好：\(scenePrompt)"
                ],
                constraints: [
                    "sceneGuard": "只在不改变任务目标的前提下应用当前应用场景偏好。"
                ],
                userPrompt: nil,
                sourceSummary: "scene.policy.v1",
                isMutable: true
            )

            return layer.hasContent ? layer : nil
        }
    }

    static func lane() -> V4PromptLayerProvider {
        V4PromptLayerProvider(name: .lane, priority: 3) { context in
            let guidance: String
            let constraints: String

            switch context.lane {
            case .directDictation:
                guidance = "当前 lane：普通听写。优先保留用户原话，只做必要清洗和最小修正。"
                constraints = "不要附加解释，不要把听写内容变成分析或总结。"
            case .selectionRewrite:
                guidance = "当前 lane：魔术先生。要把用户口头指令变成可执行动作，或者变成明确的文字处理结果。"
                constraints = "如果同一句里混了多个外部动作，先要求用户拆开说。"
            case .brainstormDiscussion:
                guidance = "当前 lane：一口气全念对。要把讨论整理成可直接给 AI 的上下文包。"
                constraints = "优先保留讨论脉络、结论和行动项，不要只给空泛摘要。"
            }

            return V4PromptLayer(
                id: V4PromptLayerName.lane.rawValue,
                name: .lane,
                priority: 3,
                systemPrompt: nil,
                guidance: ["laneBehavior": guidance],
                constraints: ["laneConstraint": constraints],
                userPrompt: nil,
                sourceSummary: "v4.lane.rules",
                isMutable: false
            )
        }
    }

    static func task() -> V4PromptLayerProvider {
        V4PromptLayerProvider(name: .task, priority: 4) { context in
            let sourceText = latestSourceText(from: context)
            let userPrompt: String

            switch context.lane {
            case .directDictation:
                userPrompt = """
                任务目标：
                \(context.goalSummary)

                听写文本：
                \(sourceText)
                """

            case .selectionRewrite:
                userPrompt = """
                任务目标：
                \(context.goalSummary)

                待处理文本：
                \(sourceText)
                """

            case .brainstormDiscussion:
                userPrompt = """
                讨论目标：
                \(context.goalSummary)

                讨论原文：
                \(sourceText)
                """
            }

            return V4PromptLayer(
                id: V4PromptLayerName.task.rawValue,
                name: .task,
                priority: 4,
                systemPrompt: nil,
                guidance: [:],
                constraints: [:],
                userPrompt: userPrompt,
                sourceSummary: "v4.task.request",
                isMutable: true
            )
        }
    }

    private static func latestSourceText(from context: V4PromptContext) -> String {
        if let latestOutput = context.stepRecords.reversed().compactMap(\.outputSummary).first {
            let normalized = latestOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                return normalized
            }
        }

        if let selectionText = context.selectionText?.trimmingCharacters(in: .whitespacesAndNewlines), !selectionText.isEmpty {
            return selectionText
        }

        let normalizedInput = context.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedInput.isEmpty ? context.goalSummary : normalizedInput
    }
}


import XCTest
@testable import PulseType

@MainActor
final class V4PromptStackResolverTests: XCTestCase {
    func testPromptLayerOrderAndOverride() async {
        let resolver = V4PromptStackResolver(
            providers: [
                makeProvider(name: .task, priority: 4, userPrompt: "task-user"),
                makeProvider(name: .lane, priority: 3, guidance: ["shared": "lane-wins"]),
                makeProvider(name: .global, priority: 0, systemPrompt: "global-system", guidance: ["shared": "global"]),
                makeProvider(name: .appScene, priority: 2, guidance: ["shared": "app-scene"]),
                makeProvider(name: .nowYouSeeMe, priority: 1, systemPrompt: "nym-system")
            ]
        )

        let stack = await resolver.resolve(context: makeContext())

        XCTAssertEqual(stack.appliedLayers.map(\.name), [.global, .nowYouSeeMe, .appScene, .lane, .task])
        XCTAssertEqual(stack.guidance["shared"], "lane-wins")
        XCTAssertEqual(stack.finalUserPrompt, "task-user")
        XCTAssertTrue(stack.finalSystemPrompt.contains("[Global]"))
        XCTAssertTrue(stack.finalSystemPrompt.contains("[NowYouSeeMe]"))
    }

    func testNowYouSeeMeRulesMapToPromptLayers() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let skillRuleStore = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.tests.v4.prompt")
        skillRuleStore.setEnabled(true, for: .spokenFilter)
        skillRuleStore.setParameter("嗯,啊", for: .spokenFilter)
        skillRuleStore.setEnabled(true, for: .systemPrompt)
        skillRuleStore.setParameter("请更直接。", for: .systemPrompt)
        skillRuleStore.setEnabled(true, for: .appPreferenceBoost)

        let appScenePolicyStore = AppScenePolicyStore(defaults: defaults)
        appScenePolicyStore.upsertPolicy(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            appPrompt: "优先输出可直接粘贴的结果。"
        )

        let resolver = V4PromptStackResolver(
            providers: V4PromptLayerProviders.live(
                skillRuleBridge: V4SkillRuleBridge(skillRuleStore: skillRuleStore),
                appScenePolicyStore: appScenePolicyStore
            )
        )

        let stack = await resolver.resolve(
            context: makeContext(appName: "TextEdit", bundleID: "com.apple.TextEdit")
        )

        XCTAssertTrue(stack.finalSystemPrompt.contains("请更直接。"))
        XCTAssertTrue(stack.finalGuidancePrompt.contains("输入清洗策略"))
        XCTAssertTrue(stack.finalGuidancePrompt.contains("优先输出可直接粘贴的结果"))
        XCTAssertTrue(stack.appliedLayers.map(\.name).contains(.nowYouSeeMe))
        XCTAssertTrue(stack.appliedLayers.map(\.name).contains(.appScene))
        XCTAssertEqual(stack.appliedSkillRuleIDs, [.spokenFilter, .systemPrompt, .appPreferenceBoost])
    }

    func testDisabledRuleNotInjected() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let skillRuleStore = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.tests.v4.prompt")
        skillRuleStore.setEnabled(false, for: .spokenFilter)
        skillRuleStore.setEnabled(false, for: .systemPrompt)
        skillRuleStore.setEnabled(false, for: .appPreferenceBoost)

        let appScenePolicyStore = AppScenePolicyStore(defaults: defaults)
        appScenePolicyStore.upsertPolicy(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            appPrompt: "这段提示不该被注入。"
        )

        let resolver = V4PromptStackResolver(
            providers: V4PromptLayerProviders.live(
                skillRuleBridge: V4SkillRuleBridge(skillRuleStore: skillRuleStore),
                appScenePolicyStore: appScenePolicyStore
            )
        )

        let stack = await resolver.resolve(
            context: makeContext(appName: "TextEdit", bundleID: "com.apple.TextEdit")
        )

        XCTAssertFalse(stack.finalGuidancePrompt.contains("输入清洗策略"))
        XCTAssertFalse(stack.finalGuidancePrompt.contains("这段提示不该被注入"))
        XCTAssertFalse(stack.appliedLayers.map(\.name).contains(.nowYouSeeMe))
        XCTAssertFalse(stack.appliedLayers.map(\.name).contains(.appScene))
        XCTAssertTrue(stack.appliedSkillRuleIDs.isEmpty)
    }

    private func makeProvider(
        name: V4PromptLayerName,
        priority: Int,
        systemPrompt: String? = nil,
        guidance: [String: String] = [:],
        constraints: [String: String] = [:],
        userPrompt: String? = nil
    ) -> V4PromptLayerProvider {
        V4PromptLayerProvider(name: name, priority: priority) { _ in
            V4PromptLayer(
                id: name.rawValue,
                name: name,
                priority: priority,
                systemPrompt: systemPrompt,
                guidance: guidance,
                constraints: constraints,
                userPrompt: userPrompt,
                sourceSummary: "test.\(name.rawValue)",
                isMutable: true
            )
        }
    }

    private func makeContext(
        appName: String? = "TextEdit",
        bundleID: String? = "com.apple.TextEdit"
    ) -> V4PromptContext {
        V4PromptContext(
            traceID: V4TraceID(rawValue: "trace-prompt"),
            lane: .selectionRewrite,
            goalSummary: "把选中文本改成更直接的版本",
            inputText: "把这段话改得更直接",
            sourceAppName: appName,
            sourceBundleID: bundleID,
            selectionText: "原始选中文本",
            stepRecords: [],
            evidenceSummary: "",
            requestedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
    }

    private var defaultsSuiteName: String {
        "V4PromptStackResolverTests.\(name)"
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Unable to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}


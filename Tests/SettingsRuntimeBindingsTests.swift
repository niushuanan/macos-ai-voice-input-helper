import XCTest
@testable import PulseType

@MainActor
final class SettingsRuntimeBindingsTests: XCTestCase {
    func testSkillRulesAndScenePolicyFlowIntoPromptResolver() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let skillRuleStore = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.settings.runtime.tests")
        skillRuleStore.setEnabled(true, for: .spokenFilter)
        skillRuleStore.setParameter("嗯,然后", for: .spokenFilter)
        skillRuleStore.setEnabled(true, for: .systemPrompt)
        skillRuleStore.setParameter("请直接给结论。", for: .systemPrompt)
        skillRuleStore.setEnabled(true, for: .appPreferenceBoost)

        let appScenePolicyStore = AppScenePolicyStore(defaults: defaults)
        appScenePolicyStore.upsertPolicy(
            appName: "Mail",
            bundleID: "com.apple.mail",
            appPrompt: "优先整理成适合发邮件的正式语气。"
        )

        let resolver = V4PromptStackResolver(
            providers: V4PromptLayerProviders.live(
                skillRuleBridge: V4SkillRuleBridge(skillRuleStore: skillRuleStore),
                appScenePolicyStore: appScenePolicyStore
            )
        )

        let stack = await resolver.resolve(
            context: V4PromptContext(
                traceID: V4TraceID(rawValue: "trace-settings-runtime"),
                lane: .selectionRewrite,
                goalSummary: "整理一封邮件",
                inputText: "给客户回一封邮件",
                sourceAppName: "Mail",
                sourceBundleID: "com.apple.mail",
                selectionText: "原文",
                selectedFiles: [],
                stepRecords: [],
                evidenceSummary: "",
                requestedAt: Date(timeIntervalSince1970: 1_710_000_100)
            )
        )

        XCTAssertTrue(stack.finalSystemPrompt.contains("请直接给结论。"))
        XCTAssertTrue(stack.finalGuidancePrompt.contains("输入清洗策略"))
        XCTAssertTrue(stack.finalGuidancePrompt.contains("适合发邮件的正式语气"))
    }

    func testFeatureToggleStoreImmediatelyChangesPermissionGateDecision() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.settings.runtime.tests",
            legacyStorageKey: "magician.permission_scopes.settings.runtime.tests",
            legacyFeatureStorageKey: "magician.features.v1.settings.runtime.tests"
        )
        let gate = V4PermissionGate(featureToggleStore: store)
        let spec = V4ToolSpec(
            toolName: "md.pipeline",
            displayName: "Markdown 文档",
            summary: "生成 Markdown 文档",
            supportedLanes: V4Lane.allCases,
            inputSchemaVersion: "v1",
            inputSchema: V4ToolInputSchema(fields: []),
            requiresPermission: true,
            requiredFeature: .markdownDocument,
            isConcurrencySafe: true,
            mutatesUserData: false,
            supportsStreamingResults: false
        )
        let request = V4RunRequest(
            sessionID: V4SessionID(rawValue: "session"),
            runID: V4RunID(rawValue: "run"),
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "整理成 Markdown",
            inputText: "把它整理成文档"
        )

        store.setEnabled(false, for: .markdownDocument)
        let denied = await gate.evaluate(spec: spec, request: request)
        XCTAssertEqual(denied.behavior, .deny)

        store.setEnabled(true, for: .markdownDocument)
        let allowed = await gate.evaluate(spec: spec, request: request)
        XCTAssertEqual(allowed.behavior, .allow)
    }

    func testHotkeySettingsImmediatelyUpdateRuntimeFacingText() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = HotkeyStateStore(defaults: defaults)
        store.setModifier(.leftCommand, for: .wakeSession)
        store.setBrainstormModifier(.rightOption)
        store.refresh()

        XCTAssertEqual(store.wakeShortcutText, "单键触发 · 左 Command")
        XCTAssertEqual(store.registrationText(for: .wakeSession), "单键触发：左 Command")
        XCTAssertEqual(store.brainstormShortcutText, "双击修饰键 · 右 Option")
    }

    private var defaultsSuiteName: String {
        "SettingsRuntimeBindingsTests.\(name)"
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Unable to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}

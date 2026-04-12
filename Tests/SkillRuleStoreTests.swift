import XCTest
@testable import PulseType

@MainActor
final class SkillRuleStoreTests: XCTestCase {
    func testRuleChangesPersistAcrossStoreReload() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.tests")
        store.setEnabled(false, for: .autoPolish)
        store.setParameter("呃,然后", for: .spokenFilter)
        store.setEnabled(true, for: .spokenFilter)

        let reloaded = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.tests")

        XCTAssertFalse(reloaded.rule(for: .autoPolish).isEnabled)
        XCTAssertEqual(reloaded.rule(for: .spokenFilter).parameter, "呃,然后")
        XCTAssertTrue(reloaded.rule(for: .spokenFilter).isEnabled)
    }

    func testApplyDictationFallsBackToOriginalWhenPipelineBecomesEmpty() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.tests")
        store.setEnabled(true, for: .spokenFilter)
        store.setParameter("hello", for: .spokenFilter)
        store.setEnabled(false, for: .autoPolish)
        store.setEnabled(false, for: .autoStructure)
        store.setEnabled(false, for: .appPreferenceBoost)

        let output = store.applyDictation("hello", outputBias: .neutral)

        XCTAssertEqual(output.text, "hello")
        XCTAssertTrue(output.appliedSkills.isEmpty)
    }

    func testApplyDictationReturnsHitSkillTags() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.tests")
        store.setEnabled(true, for: .spokenFilter)
        store.setParameter("嗯", for: .spokenFilter)
        store.setEnabled(false, for: .autoStructure)
        store.setEnabled(false, for: .appPreferenceBoost)

        let output = store.applyDictation("嗯 你好  。", outputBias: .neutral)

        XCTAssertEqual(output.text, "你好 。")
        XCTAssertEqual(output.appliedSkills, [.spokenFilter])
    }

    func testApplyDictationSupportsChineseCommaSeparatedSpokenFilterTokens() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.tests")
        store.setEnabled(true, for: .spokenFilter)
        store.setParameter("嗯，啊，呃", for: .spokenFilter)

        let output = store.applyDictation("嗯 啊 呃 好的", outputBias: .neutral)

        XCTAssertEqual(output.text, "好的")
        XCTAssertEqual(output.appliedSkills, [.spokenFilter])
    }

    func testApplyDictationSupportsMixedSeparatorsInSpokenFilterTokens() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.tests")
        store.setEnabled(true, for: .spokenFilter)
        store.setParameter("嗯,啊,就是,那个,然后，呃", for: .spokenFilter)

        let output = store.applyDictation("然后 呃 这块先不动", outputBias: .neutral)

        XCTAssertEqual(output.text, "这块先不动")
        XCTAssertEqual(output.appliedSkills, [.spokenFilter])
    }

    func testApplyDictationCollapsesCommonASRStutterForModifiers() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.tests")
        store.setEnabled(false, for: .spokenFilter)

        let output = store.applyDictation("右右 shift shift 开始", outputBias: .neutral)

        XCTAssertEqual(output.text, "右 shift 开始")
        XCTAssertTrue(output.appliedSkills.isEmpty)
    }

    func testApplyDictationKeepsNormalRepeatedWords() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.tests")
        store.setEnabled(false, for: .spokenFilter)

        let output = store.applyDictation("哈哈 哈哈 真好", outputBias: .neutral)

        XCTAssertEqual(output.text, "哈哈 哈哈 真好")
        XCTAssertTrue(output.appliedSkills.isEmpty)
    }

    func testLegacyRulesRemainDecodableButNoLongerAffectPipeline() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let legacyRules = [
            SkillRule(id: .autoPolish, isEnabled: true, parameter: "标准"),
            SkillRule(id: .spokenFilter, isEnabled: false, parameter: "嗯"),
            SkillRule(id: .autoStructure, isEnabled: true, parameter: "要点列表"),
            SkillRule(id: .appPreferenceBoost, isEnabled: false, parameter: "自动"),
            SkillRule(id: .systemPrompt, isEnabled: true, parameter: "保留重点")
        ]
        let data = try JSONEncoder().encode(legacyRules)
        defaults.set(data, forKey: "skill.rules.tests")

        let store = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.tests")
        let output = store.applyDictation("嗯 你好  。再见。", outputBias: .structured)

        XCTAssertTrue(store.rule(for: .autoPolish).isEnabled)
        XCTAssertTrue(store.rule(for: .autoStructure).isEnabled)
        XCTAssertEqual(output.text, "嗯 你好  。再见。")
        XCTAssertTrue(output.appliedSkills.isEmpty)
    }

    func testVisibleRulesHideLegacyAndAppStyleRows() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.tests")
        let visibleRuleIDs = store.visibleRules().map(\.id)

        XCTAssertEqual(visibleRuleIDs, [.spokenFilter, .systemPrompt])
    }

    private var defaultsSuiteName: String {
        "SkillRuleStoreTests.\(name)"
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Unable to build isolated UserDefaults suite for tests.")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}

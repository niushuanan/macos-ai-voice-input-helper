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

        XCTAssertEqual(output, "hello")
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

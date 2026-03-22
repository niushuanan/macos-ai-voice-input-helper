import XCTest
@testable import PulseType

@MainActor
final class AppScenePolicyStoreTests: XCTestCase {
    func testLegacyOutputBiasDataMigratesToAppPrompt() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let legacy = [
            LegacyScenePolicy(
                id: "com.apple.TextEdit",
                appName: "TextEdit",
                bundleID: "com.apple.TextEdit",
                outputBias: .formal,
                preferSelectionRewrite: false
            )
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "scene.policy.v1")

        let store = AppScenePolicyStore(defaults: defaults)

        XCTAssertEqual(store.policies.count, 1)
        XCTAssertEqual(store.policies.first?.bundleID, "com.apple.TextEdit")
        XCTAssertFalse(store.policies.first?.appPrompt.isEmpty ?? true)
    }

    func testPromptPolicyPersistsAcrossReload() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = AppScenePolicyStore(defaults: defaults)
        store.upsertPolicy(
            appName: "Codex",
            bundleID: "com.openai.codex",
            appPrompt: "请尽量简洁，优先给可执行结论。"
        )

        let reloaded = AppScenePolicyStore(defaults: defaults)
        XCTAssertEqual(reloaded.policies.count, 1)
        XCTAssertEqual(reloaded.policies.first?.appName, "Codex")
        XCTAssertEqual(reloaded.policies.first?.appPrompt, "请尽量简洁，优先给可执行结论。")
    }

    func testFallbackPolicyUsesEmptyPromptWhenNoStoredRule() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = AppScenePolicyStore(defaults: defaults)
        let policy = store.policy(
            for: FocusedAppContext(
                appName: "Notes",
                bundleID: "com.apple.Notes",
                focusedRole: "AXTextArea",
                hasEditableTarget: true,
                strategyHint: ""
            )
        )

        XCTAssertEqual(policy.bundleID, "com.apple.Notes")
        XCTAssertEqual(policy.appPrompt, "")
    }

    private var defaultsSuiteName: String {
        "AppScenePolicyStoreTests.\(name)"
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Unable to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}

private struct LegacyScenePolicy: Codable {
    let id: String
    let appName: String
    let bundleID: String
    let outputBias: AppOutputBias
    let preferSelectionRewrite: Bool
}

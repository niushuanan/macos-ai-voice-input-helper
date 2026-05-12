import XCTest
@testable import PulseType

@MainActor
final class V4ModelSlotManagerTests: XCTestCase {
    func testModelSlotResolutionForAsrTextAgent() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let manager = makeManager(defaults: defaults)
        let slots = try await manager.resolveAll()

        XCTAssertEqual(slots.asr.slot, .asr)
        XCTAssertEqual(slots.asr.sourceConfigurationKey, "asrConfig")
        XCTAssertEqual(slots.asr.providerType, .dashScopeQwenASR)
        XCTAssertEqual(slots.asr.modelName, "qwen3-asr-flash")

        XCTAssertEqual(slots.text.slot, .text)
        XCTAssertEqual(slots.text.sourceConfigurationKey, "textConfig")
        XCTAssertEqual(slots.text.providerType, .openAICompatible)
        XCTAssertEqual(slots.text.modelName, "deepseek-v4-flash")

        XCTAssertEqual(slots.agent.slot, .agent)
        XCTAssertEqual(slots.agent.sourceConfigurationKey, "cliTextConfig")
        XCTAssertEqual(slots.agent.providerType, .openAICompatible)
        XCTAssertEqual(slots.agent.modelName, "deepseek-v4-flash")
    }

    func testInvalidModelConfigReturnsStructuredError() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let credentials = MemoryCredentialStoreForV4ModelTests()
        let store = ProviderSettingsStore(defaults: defaults, credentialStore: credentials)
        store.updateTextModel("bad model")

        let manager = V4ModelSlotManager(
            bridge: V4ProviderSettingsBridge(providerSettingsStore: store)
        )

        do {
            _ = try await manager.resolve(.text)
            XCTFail("expected structured error")
        } catch let error as V4ModelSlotResolutionError {
            XCTAssertEqual(error.slot, .text)
            XCTAssertEqual(error.code, .invalidConfiguration)
            XCTAssertEqual(error.sourceConfigurationKey, "textConfig")
            XCTAssertTrue(error.message.contains("模型名"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAgentDefaultsToCliTextSlot() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let credentials = MemoryCredentialStoreForV4ModelTests()
        let store = ProviderSettingsStore(defaults: defaults, credentialStore: credentials)
        store.updateTextModel("deepseek-v4-flash")
        store.updateCLITextModel("gpt-4.1-mini")

        let manager = V4ModelSlotManager(
            bridge: V4ProviderSettingsBridge(providerSettingsStore: store)
        )

        let agentEndpoint = try await manager.resolve(.agent)
        let textEndpoint = try await manager.resolve(.text)

        XCTAssertEqual(agentEndpoint.sourceConfigurationKey, "cliTextConfig")
        XCTAssertEqual(agentEndpoint.modelName, "gpt-4.1-mini")
        XCTAssertEqual(textEndpoint.modelName, "deepseek-v4-flash")
    }

    private func makeManager(defaults: UserDefaults) -> V4ModelSlotManager {
        let credentials = MemoryCredentialStoreForV4ModelTests()
        let store = ProviderSettingsStore(defaults: defaults, credentialStore: credentials)
        return V4ModelSlotManager(
            bridge: V4ProviderSettingsBridge(providerSettingsStore: store)
        )
    }

    private var defaultsSuiteName: String {
        "V4ModelSlotManagerTests.\(name)"
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Unable to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}

private final class MemoryCredentialStoreForV4ModelTests: ProviderCredentialStore {
    private var storage: [String: String] = [:]

    func loadAPIKey(for profileID: String) throws -> String? {
        storage[profileID]
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {
        storage[profileID] = value
    }

    func deleteAPIKey(for profileID: String) throws {
        storage.removeValue(forKey: profileID)
    }

    func containsAPIKey(for profileID: String, allowUserInteraction _: Bool) throws -> Bool {
        storage[profileID] != nil
    }
}

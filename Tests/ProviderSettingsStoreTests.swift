import XCTest
@testable import PulseType

@MainActor
final class ProviderSettingsStoreTests: XCTestCase {
    func testDefaultConfigurationUsesQwenForASRAndDeepSeekForText() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let credentials = MemoryCredentialStoreForSettingsTests()
        let store = ProviderSettingsStore(defaults: defaults, credentialStore: credentials)

        XCTAssertEqual(store.asrConfig.providerType, .dashScopeQwenASR)
        XCTAssertEqual(store.asrConfig.baseURLString, "https://dashscope.aliyuncs.com")
        XCTAssertEqual(store.asrConfig.modelName, "qwen3-asr-flash")

        XCTAssertEqual(store.textConfig.providerType, .openAICompatible)
        XCTAssertEqual(store.textConfig.baseURLString, "https://api.deepseek.com")
        XCTAssertEqual(store.textConfig.modelName, "deepseek-chat")
    }

    func testSwitchToLocalSenseVoiceAutoFillsModelPath() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let credentials = MemoryCredentialStoreForSettingsTests()
        let store = ProviderSettingsStore(defaults: defaults, credentialStore: credentials)

        store.updateASRProviderType(.localSenseVoice)

        XCTAssertEqual(store.asrConfig.providerType, .localSenseVoice)
        XCTAssertEqual(store.asrConfig.localModelPath, defaultSenseVoiceModelPath)
    }

    func testRecordedModelTestResultsPersistAcrossStoreReload() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let credentials = MemoryCredentialStoreForSettingsTests()
        let store = ProviderSettingsStore(defaults: defaults, credentialStore: credentials)

        let asrResult = ConnectionTestResult.success(
            message: "ASR 可用",
            hint: "接口正常",
            httpStatus: 200
        )
        let textResult = ConnectionTestResult.failure(
            message: "文本模型失败：HTTP 401",
            hint: "请检查密钥是否正确",
            httpStatus: 401
        )

        store.recordASRTestResult(asrResult)
        store.recordTextTestResult(textResult)

        let reloaded = ProviderSettingsStore(defaults: defaults, credentialStore: credentials)

        XCTAssertEqual(reloaded.latestASRTestResult?.status, .success)
        XCTAssertEqual(reloaded.latestASRTestResult?.httpStatus, 200)
        XCTAssertEqual(reloaded.latestASRTestResult?.hint, "接口正常")

        XCTAssertEqual(reloaded.latestTextTestResult?.status, .failure)
        XCTAssertEqual(reloaded.latestTextTestResult?.httpStatus, 401)
        XCTAssertTrue(reloaded.latestTextTestResult?.hint.contains("密钥") == true)
    }

    func testConnectionTestResultCodablePreservesStatusMapping() throws {
        let original = ConnectionTestResult.failure(
            message: "HTTP 429",
            hint: "请检查额度",
            httpStatus: 429
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionTestResult.self, from: data)

        XCTAssertEqual(decoded.status, .failure)
        XCTAssertEqual(decoded.httpStatus, 429)
        XCTAssertEqual(decoded.hint, "请检查额度")
    }

    private var defaultsSuiteName: String {
        "ProviderSettingsStoreTests.\(name)"
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Unable to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}

private final class MemoryCredentialStoreForSettingsTests: ProviderCredentialStore {
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

    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool {
        storage[profileID]?.isEmpty == false
    }
}

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

        XCTAssertEqual(store.cliTextConfig.providerType, .openAICompatible)
        XCTAssertEqual(store.cliTextConfig.baseURLString, "https://api.deepseek.com")
        XCTAssertEqual(store.cliTextConfig.modelName, "deepseek-chat")
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

    func testCLIAPIKeyFallsBackToTextAPIKeyWhenCLIKeyMissing() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let credentials = MemoryCredentialStoreForSettingsTests()
        try credentials.saveAPIKey("sk-text-fallback-0001", for: defaultTextCredentialKeyRef)

        let store = ProviderSettingsStore(defaults: defaults, credentialStore: credentials)

        let cliKey = try store.loadAPIKeyForCLIProvider()
        XCTAssertEqual(cliKey, "sk-text-fallback-0001")
        XCTAssertEqual(store.cliTextCredentialState, .saved)
    }

    func testCLIAPIKeyUsesDedicatedKeyWhenProvided() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let credentials = MemoryCredentialStoreForSettingsTests()
        try credentials.saveAPIKey("sk-text-default-9999", for: defaultTextCredentialKeyRef)
        try credentials.saveAPIKey("sk-cli-dedicated-1234", for: defaultCLITextCredentialKeyRef)

        let store = ProviderSettingsStore(defaults: defaults, credentialStore: credentials)

        let cliKey = try store.loadAPIKeyForCLIProvider()
        XCTAssertEqual(cliKey, "sk-cli-dedicated-1234")
    }

    func testCredentialStateUsesInaccessibleWhenPassiveProbeNeedsInteraction() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let credentials = MemoryCredentialStoreForSettingsTests()
        credentials.containsBehavior = .error(.interactionRequired)

        let store = ProviderSettingsStore(defaults: defaults, credentialStore: credentials)

        XCTAssertEqual(store.asrCredentialState, .inaccessible)
        XCTAssertEqual(store.textCredentialState, .inaccessible)
        XCTAssertTrue(store.asrFeedbackMessage?.contains("重新保存") == true)
    }

    func testCredentialStateUsesFailedStatusWhenPassiveProbeFails() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let credentials = MemoryCredentialStoreForSettingsTests()
        credentials.containsBehavior = .error(.unexpectedStatus(errSecAuthFailed))

        let store = ProviderSettingsStore(defaults: defaults, credentialStore: credentials)

        XCTAssertEqual(store.asrCredentialState, .failed(errSecAuthFailed))
        XCTAssertEqual(store.textCredentialState, .failed(errSecAuthFailed))
        XCTAssertTrue(store.textFeedbackMessage?.contains("OSStatus") == true)
    }

    func testSavingASRDraftMarksCredentialAsSavedAfterReadBack() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let credentials = MemoryCredentialStoreForSettingsTests()
        let store = ProviderSettingsStore(defaults: defaults, credentialStore: credentials)
        store.asrAPIKeyDraft = "sk-asr-demo-1234"

        XCTAssertTrue(store.saveASRAPIKeyDraft())

        XCTAssertEqual(store.asrCredentialState, .saved)
        XCTAssertEqual(try? credentials.loadAPIKey(for: store.asrConfig.keyRef), "sk-asr-demo-1234")
        XCTAssertEqual(store.asrAPIKeyDraft, "")
        XCTAssertTrue(store.asrFeedbackMessage?.contains("已保存") == true)
    }

    func testSavingDraftMapsReadBackMismatchToFailedState() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let credentials = MemoryCredentialStoreForSettingsTests()
        credentials.loadBehavior = .fixed(nil)

        let store = ProviderSettingsStore(defaults: defaults, credentialStore: credentials)
        store.textAPIKeyDraft = "sk-text-demo-5678"

        XCTAssertFalse(store.saveTextAPIKeyDraft())

        XCTAssertEqual(store.textCredentialState, .failed(nil))
        XCTAssertTrue(store.textFeedbackMessage?.contains("校验失败") == true)
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
    enum LoadBehavior {
        case storage
        case fixed(String?)
        case error(ProviderCredentialStoreError)
    }

    enum SaveBehavior {
        case storage
        case error(ProviderCredentialStoreError)
    }

    enum ContainsBehavior {
        case storage
        case fixed(Bool)
        case error(ProviderCredentialStoreError)
    }

    private var storage: [String: String] = [:]
    var loadBehavior: LoadBehavior = .storage
    var saveBehavior: SaveBehavior = .storage
    var containsBehavior: ContainsBehavior = .storage

    func loadAPIKey(for profileID: String) throws -> String? {
        switch loadBehavior {
        case .storage:
            return storage[profileID]
        case let .fixed(value):
            return value
        case let .error(error):
            throw error
        }
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {
        switch saveBehavior {
        case .storage:
            break
        case let .error(error):
            throw error
        }
        storage[profileID] = value
    }

    func deleteAPIKey(for profileID: String) throws {
        storage.removeValue(forKey: profileID)
    }

    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool {
        switch containsBehavior {
        case .storage:
            return storage[profileID]?.isEmpty == false
        case let .fixed(value):
            return value
        case let .error(error):
            throw error
        }
    }
}

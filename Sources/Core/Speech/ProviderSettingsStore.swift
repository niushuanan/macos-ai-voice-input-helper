import Combine
import Foundation

@MainActor
final class ProviderSettingsStore: ObservableObject {
    enum CredentialState: Equatable {
        case unknown
        case missing
        case saving
        case saved
        case inaccessible
        case failed(OSStatus?)
    }

    @Published var asrConfig: ASRConfig {
        didSet {
            persistASRConfig()
            if asrConfig != oldValue {
                clearASRTestResult()
            }
        }
    }

    @Published var textConfig: TextConfig {
        didSet {
            persistTextConfig()
            if textConfig != oldValue {
                clearTextTestResult()
            }
        }
    }

    @Published var cliTextConfig: TextConfig {
        didSet {
            persistCLITextConfig()
            if cliTextConfig != oldValue {
                clearCLITextTestResult()
            }
        }
    }

    @Published var feishuCLIExecutablePathOverride: String {
        didSet {
            persistFeishuCLIExecutablePathOverride()
        }
    }

    @Published var asrAPIKeyDraft: String = ""
    @Published var textAPIKeyDraft: String = ""
    @Published var cliTextAPIKeyDraft: String = ""

    @Published private(set) var asrCredentialState: CredentialState = .unknown
    @Published private(set) var textCredentialState: CredentialState = .unknown
    @Published private(set) var cliTextCredentialState: CredentialState = .unknown
    @Published private(set) var asrFeedbackMessage: String?
    @Published private(set) var textFeedbackMessage: String?
    @Published private(set) var cliTextFeedbackMessage: String?
    @Published private(set) var latestASRTestResult: ConnectionTestResult?
    @Published private(set) var latestTextTestResult: ConnectionTestResult?
    @Published private(set) var latestCLITextTestResult: ConnectionTestResult?

    var feedbackMessage: String? {
        textFeedbackMessage ?? asrFeedbackMessage
    }

    var selectedTranscriptionProviderName: String {
        asrConfig.providerType.displayName
    }

    var selectedRewriteProviderName: String {
        textConfig.providerType.displayName
    }

    var selectedProviderName: String {
        selectedTranscriptionProviderName
    }

    var modelName: String {
        asrConfig.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var rewriteModelName: String {
        textConfig.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var cliRewriteModelName: String {
        cliTextConfig.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var asrConfigurationValidationMessage: String? {
        ProviderConfigurationValidator.validationMessage(
            providerType: asrConfig.providerType,
            baseURLString: asrConfig.baseURLString,
            modelName: asrConfig.modelName
        )
    }

    var textConfigurationValidationMessage: String? {
        ProviderConfigurationValidator.validationMessage(
            providerType: textConfig.providerType,
            baseURLString: textConfig.baseURLString,
            modelName: textConfig.modelName
        )
    }

    var cliTextConfigurationValidationMessage: String? {
        ProviderConfigurationValidator.validationMessage(
            providerType: cliTextConfig.providerType,
            baseURLString: cliTextConfig.baseURLString,
            modelName: cliTextConfig.modelName
        )
    }

    var configurationValidationMessage: String? {
        asrConfigurationValidationMessage
    }

    var rewriteConfigurationValidationMessage: String? {
        textConfigurationValidationMessage
    }

    var isConfigurationValid: Bool {
        asrConfigurationValidationMessage == nil
    }

    var isRewriteConfigurationValid: Bool {
        textConfigurationValidationMessage == nil
    }

    var isCLITextConfigurationValid: Bool {
        cliTextConfigurationValidationMessage == nil
    }

    var configuration: SpeechProviderConfiguration {
        transcriptionConfiguration ?? fallbackTranscriptionConfiguration()
    }

    var rewriteConfiguration: TextGenerationProviderConfiguration {
        resolvedRewriteConfiguration() ?? fallbackRewriteConfiguration()
    }

    var cliRewriteConfiguration: TextGenerationProviderConfiguration {
        resolvedCLIRewriteConfiguration() ?? fallbackCLIRewriteConfiguration()
    }

    var transcriptionConfiguration: SpeechProviderConfiguration? {
        resolvedTranscriptionConfiguration()
    }

    var resolvedFeishuCLIExecutablePathOverride: String? {
        let normalized = Self.sanitizeCLIExecutablePathOverride(feishuCLIExecutablePathOverride)
        return normalized.isEmpty ? nil : normalized
    }

    var credentialState: CredentialState {
        asrCredentialState
    }

    private let defaults: UserDefaults
    private let credentialStore: ProviderCredentialStore
    private let defaultsASRConfigKey = "providers.asr.config.v2"
    private let defaultsTextConfigKey = "providers.text.config.v2"
    private let defaultsCLITextConfigKey = "providers.text.cli.config.v1"
    private let defaultsFeishuCLIExecutablePathOverrideKey = "providers.feishu.cli.path.override.v1"
    private let defaultsLatestASRTestResultKey = "providers.asr.test.result.v1"
    private let defaultsLatestTextTestResultKey = "providers.text.test.result.v1"
    private let defaultsLatestCLITextTestResultKey = "providers.text.cli.test.result.v1"

    init(
        defaults: UserDefaults = .standard,
        credentialStore: ProviderCredentialStore
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore

        let decodedASRConfig = Self.decodeASRConfig(
            from: defaults.data(forKey: defaultsASRConfigKey)
        )
        let decodedTextConfig = Self.decodeTextConfig(
            from: defaults.data(forKey: defaultsTextConfigKey)
        )
        let decodedCLITextConfig = Self.decodeTextConfig(
            from: defaults.data(forKey: defaultsCLITextConfigKey)
        )

        let legacyMigration = Self.migrateLegacyConfiguration(defaults: defaults)

        let initialASRConfig = decodedASRConfig ?? legacyMigration.asrConfig
        let initialTextConfig = decodedTextConfig ?? legacyMigration.textConfig
        let initialCLITextConfig = decodedCLITextConfig ?? Self.defaultCLITextConfig()
        let sanitizedASRConfig = Self.sanitizeASRConfig(initialASRConfig)
        let sanitizedTextConfig = Self.sanitizeTextConfig(initialTextConfig)
        let sanitizedCLITextConfig = Self.sanitizeCLITextConfig(initialCLITextConfig)

        self.asrConfig = sanitizedASRConfig
        self.textConfig = sanitizedTextConfig
        self.cliTextConfig = sanitizedCLITextConfig
        self.feishuCLIExecutablePathOverride = Self.sanitizeCLIExecutablePathOverride(
            defaults.string(forKey: defaultsFeishuCLIExecutablePathOverrideKey) ?? ""
        )
        self.latestASRTestResult = Self.decodeConnectionTestResult(
            from: defaults.data(forKey: defaultsLatestASRTestResultKey)
        )
        self.latestTextTestResult = Self.decodeConnectionTestResult(
            from: defaults.data(forKey: defaultsLatestTextTestResultKey)
        )
        self.latestCLITextTestResult = Self.decodeConnectionTestResult(
            from: defaults.data(forKey: defaultsLatestCLITextTestResultKey)
        )

        persistASRConfig()
        persistTextConfig()
        persistCLITextConfig()
        persistFeishuCLIExecutablePathOverride()
        migrateLegacyCredentialsIfNeeded(using: legacyMigration)
        refreshCredentialState(allowUserInteraction: false)

        if initialASRConfig != sanitizedASRConfig {
            clearASRTestResult()
        }
        if initialTextConfig != sanitizedTextConfig {
            clearTextTestResult()
        }
        if initialCLITextConfig != sanitizedCLITextConfig {
            clearCLITextTestResult()
        }
    }

    func refreshCredentialState(allowUserInteraction: Bool = false) {
        asrCredentialState = resolveCredentialState(
            keyRef: asrConfig.keyRef,
            roleName: "语音识别",
            allowUserInteraction: allowUserInteraction
        ) { [weak self] message in
            self?.asrFeedbackMessage = message
        }
        textCredentialState = resolveCredentialState(
            keyRef: textConfig.keyRef,
            roleName: "文本模型",
            allowUserInteraction: allowUserInteraction
        ) { [weak self] message in
            self?.textFeedbackMessage = message
        }

        let cliPrimaryState = resolveCredentialState(
            keyRef: cliTextConfig.keyRef,
            roleName: "CLI 模式文本模型",
            allowUserInteraction: allowUserInteraction
        ) { [weak self] message in
            self?.cliTextFeedbackMessage = message
        }
        if cliPrimaryState == .missing, cliTextConfig.keyRef != textConfig.keyRef {
            let fallbackState = resolveCredentialState(
                keyRef: textConfig.keyRef,
                roleName: "文本模型",
                allowUserInteraction: allowUserInteraction
            ) { _ in }
            switch fallbackState {
            case .saved:
                cliTextCredentialState = .saved
                cliTextFeedbackMessage = nil
            case .inaccessible:
                cliTextCredentialState = .inaccessible
                cliTextFeedbackMessage = "CLI 模式密钥暂不可读。可先单独保存一份 CLI 密钥再重试。"
            case let .failed(status):
                cliTextCredentialState = .failed(status)
                cliTextFeedbackMessage = "CLI 模式密钥读取失败。可先单独保存一份 CLI 密钥再重试。"
            case .missing, .unknown, .saving:
                cliTextCredentialState = .missing
                cliTextFeedbackMessage = nil
            }
        } else {
            cliTextCredentialState = cliPrimaryState
        }
    }

    @discardableResult
    func saveCLITextAPIKeyDraft() -> Bool {
        saveAPIKey(
            draft: cliTextAPIKeyDraft,
            keyRef: cliTextConfig.keyRef,
            roleName: "CLI 模式文本模型",
            onSaving: { [weak self] in
                self?.cliTextCredentialState = .saving
            },
            onSuccess: { [weak self] in
                self?.cliTextAPIKeyDraft = ""
                self?.cliTextCredentialState = .saved
                self?.cliTextFeedbackMessage = "CLI 模式 API 密钥已保存。"
                self?.clearCLITextTestResult()
            },
            onFailure: { [weak self] state, message in
                self?.cliTextCredentialState = state
                self?.cliTextFeedbackMessage = message
            }
        )
    }

    @discardableResult
    func saveASRAPIKeyDraft() -> Bool {
        saveAPIKey(
            draft: asrAPIKeyDraft,
            keyRef: asrConfig.keyRef,
            roleName: "语音识别",
            onSaving: { [weak self] in
                self?.asrCredentialState = .saving
            },
            onSuccess: { [weak self] in
                self?.asrAPIKeyDraft = ""
                self?.asrCredentialState = .saved
                self?.asrFeedbackMessage = "语音识别 API 密钥已保存。"
                self?.clearASRTestResult()
            },
            onFailure: { [weak self] state, message in
                self?.asrCredentialState = state
                self?.asrFeedbackMessage = message
            }
        )
    }

    @discardableResult
    func saveTextAPIKeyDraft() -> Bool {
        saveAPIKey(
            draft: textAPIKeyDraft,
            keyRef: textConfig.keyRef,
            roleName: "文本模型",
            onSaving: { [weak self] in
                self?.textCredentialState = .saving
            },
            onSuccess: { [weak self] in
                self?.textAPIKeyDraft = ""
                self?.textCredentialState = .saved
                self?.textFeedbackMessage = "文本模型 API 密钥已保存。"
                self?.clearTextTestResult()
            },
            onFailure: { [weak self] state, message in
                self?.textCredentialState = state
                self?.textFeedbackMessage = message
            }
        )
    }

    @discardableResult
    func clearASRAPIKey() -> Bool {
        clearAPIKey(
            keyRef: asrConfig.keyRef,
            roleName: "语音识别",
            onSuccess: { [weak self] in
                self?.asrCredentialState = .missing
                self?.asrFeedbackMessage = "语音识别 API 密钥已删除。"
                self?.clearASRTestResult()
            },
            onFailure: { [weak self] message in
                self?.asrFeedbackMessage = message
            }
        )
    }

    @discardableResult
    func clearTextAPIKey() -> Bool {
        clearAPIKey(
            keyRef: textConfig.keyRef,
            roleName: "文本模型",
            onSuccess: { [weak self] in
                self?.textCredentialState = .missing
                self?.textFeedbackMessage = "文本模型 API 密钥已删除。"
                self?.clearTextTestResult()
            },
            onFailure: { [weak self] message in
                self?.textFeedbackMessage = message
            }
        )
    }

    @discardableResult
    func clearCLITextAPIKey() -> Bool {
        clearAPIKey(
            keyRef: cliTextConfig.keyRef,
            roleName: "CLI 模式文本模型",
            onSuccess: { [weak self] in
                self?.cliTextCredentialState = .missing
                self?.cliTextFeedbackMessage = "CLI 模式 API 密钥已删除。"
                self?.clearCLITextTestResult()
            },
            onFailure: { [weak self] message in
                self?.cliTextFeedbackMessage = message
            }
        )
    }

    func loadAPIKeyForTranscriptionProvider() throws -> String? {
        try credentialStore.loadAPIKey(for: asrConfig.keyRef)
    }

    func loadAPIKeyForRewriteProvider() throws -> String? {
        try credentialStore.loadAPIKey(for: textConfig.keyRef)
    }

    func loadAPIKeyForCLIProvider() throws -> String? {
        var primaryError: Error?
        do {
            if
                let primary = try credentialStore.loadAPIKey(for: cliTextConfig.keyRef)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !primary.isEmpty
            {
                return primary
            }
        } catch {
            primaryError = error
        }

        do {
            if
                let fallback = try credentialStore.loadAPIKey(for: textConfig.keyRef)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !fallback.isEmpty
            {
                return fallback
            }
        } catch {
            if primaryError == nil {
                throw error
            }
        }

        if let primaryError {
            throw primaryError
        }
        return nil
    }

    func loadAPIKeyForActiveProvider() throws -> String? {
        try credentialStore.loadAPIKey(for: asrConfig.keyRef)
    }

    func updateASRProviderType(_ type: ProviderType) {
        guard type.supportsTranscription else {
            return
        }
        var updated = asrConfig
        updated.providerType = type
        if !type.allowsCustomBaseURL {
            updated.baseURLString = type.recommendedBaseURLString
        }
        updated.modelName = type.defaultTranscriptionModelName
        if type == .localSenseVoice {
            let currentPath = updated.localModelPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.localModelPath = (currentPath?.isEmpty == false) ? currentPath : defaultSenseVoiceModelPath
        }
        asrConfig = updated
    }

    func updateTextProviderType(_ type: ProviderType) {
        guard type.supportsRewrite else {
            return
        }
        var updated = textConfig
        let previousProviderType = updated.providerType
        let previousBaseURLString = updated.baseURLString
        updated.providerType = type
        if !type.allowsCustomBaseURL {
            updated.baseURLString = type.recommendedBaseURLString
        } else if Self.shouldResetCompatibleBaseURL(
            previousProviderType: previousProviderType,
            previousBaseURLString: previousBaseURLString
        ) {
            updated.baseURLString = type.recommendedBaseURLString
        }
        updated.modelName = type.defaultRewriteModelName
        textConfig = updated
    }

    func updateCLITextProviderType(_ type: ProviderType) {
        guard type.supportsRewrite else {
            return
        }
        var updated = cliTextConfig
        let previousProviderType = updated.providerType
        let previousBaseURLString = updated.baseURLString
        updated.providerType = type
        if !type.allowsCustomBaseURL {
            updated.baseURLString = type.recommendedBaseURLString
        } else if Self.shouldResetCompatibleBaseURL(
            previousProviderType: previousProviderType,
            previousBaseURLString: previousBaseURLString
        ) {
            updated.baseURLString = type.recommendedBaseURLString
        }
        updated.modelName = type.defaultRewriteModelName
        cliTextConfig = updated
    }

    func updateASRBaseURL(_ value: String) {
        asrConfig.baseURLString = value
    }

    func updateTextBaseURL(_ value: String) {
        textConfig.baseURLString = value
    }

    func updateCLITextBaseURL(_ value: String) {
        cliTextConfig.baseURLString = value
    }

    func updateASRModel(_ value: String) {
        asrConfig.modelName = value
    }

    func updateASRLocalModelPath(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        asrConfig.localModelPath = normalized.isEmpty ? nil : normalized
    }

    func updateTextModel(_ value: String) {
        textConfig.modelName = value
    }

    func updateCLITextModel(_ value: String) {
        cliTextConfig.modelName = value
    }

    func updateFeishuCLIExecutablePathOverride(_ value: String) {
        feishuCLIExecutablePathOverride = Self.sanitizeCLIExecutablePathOverride(value)
    }

    func clearFeishuCLIExecutablePathOverride() {
        feishuCLIExecutablePathOverride = ""
    }

    func testASRConnection() async -> ConnectionTestResult {
        let tester = ASRConnectionTester(credentialStore: credentialStore)
        let result = await tester.test(config: asrConfig)
        recordASRTestResult(result)
        return result
    }

    func testTextConnection() async -> ConnectionTestResult {
        let tester = TextConnectionTester(credentialStore: credentialStore)
        let result = await tester.test(config: textConfig)
        recordTextTestResult(result)
        return result
    }

    func testCLITextConnection() async -> ConnectionTestResult {
        let tester = TextConnectionTester(credentialStore: credentialStore)
        var configForTest = cliTextConfig
        if !hasNonEmptyCredential(for: cliTextConfig.keyRef) {
            configForTest.keyRef = textConfig.keyRef
        }
        let result = await tester.test(config: configForTest)
        recordCLITextTestResult(result)
        return result
    }

    func recordASRTestResult(_ result: ConnectionTestResult) {
        latestASRTestResult = result
        persistLatestASRTestResult()
    }

    func recordTextTestResult(_ result: ConnectionTestResult) {
        latestTextTestResult = result
        persistLatestTextTestResult()
    }

    func recordCLITextTestResult(_ result: ConnectionTestResult) {
        latestCLITextTestResult = result
        persistLatestCLITextTestResult()
    }

    private func resolvedTranscriptionConfiguration() -> SpeechProviderConfiguration? {
        guard asrConfigurationValidationMessage == nil else {
            return nil
        }

        guard let baseURL = ProviderConfigurationValidator.resolvedBaseURL(
            providerType: asrConfig.providerType,
            baseURLString: asrConfig.baseURLString
        ) else {
            return nil
        }

        return SpeechProviderConfiguration(
            profileID: asrConfig.keyRef,
            providerType: asrConfig.providerType,
            providerName: asrConfig.providerType.displayName,
            modelName: modelName,
            baseURL: baseURL,
            localModelPath: asrConfig.localModelPath
        )
    }

    private func resolvedRewriteConfiguration() -> TextGenerationProviderConfiguration? {
        guard textConfigurationValidationMessage == nil else {
            return nil
        }

        guard let baseURL = ProviderConfigurationValidator.resolvedBaseURL(
            providerType: textConfig.providerType,
            baseURLString: textConfig.baseURLString
        ) else {
            return nil
        }

        return TextGenerationProviderConfiguration(
            profileID: textConfig.keyRef,
            providerType: textConfig.providerType,
            providerName: textConfig.providerType.displayName,
            modelName: rewriteModelName,
            baseURL: baseURL
        )
    }

    private func resolvedCLIRewriteConfiguration() -> TextGenerationProviderConfiguration? {
        guard cliTextConfigurationValidationMessage == nil else {
            return nil
        }

        guard let baseURL = ProviderConfigurationValidator.resolvedBaseURL(
            providerType: cliTextConfig.providerType,
            baseURLString: cliTextConfig.baseURLString
        ) else {
            return nil
        }

        return TextGenerationProviderConfiguration(
            profileID: cliTextConfig.keyRef,
            providerType: cliTextConfig.providerType,
            providerName: cliTextConfig.providerType.displayName,
            modelName: cliRewriteModelName,
            baseURL: baseURL
        )
    }

    private func fallbackTranscriptionConfiguration() -> SpeechProviderConfiguration {
        SpeechProviderConfiguration(
            profileID: asrConfig.keyRef,
            providerType: asrConfig.providerType,
            providerName: asrConfig.providerType.displayName,
            modelName: asrConfig.providerType.defaultTranscriptionModelName,
            baseURL: asrConfig.providerType.fixedBaseURL ?? URL(string: "https://api.openai.com")!,
            localModelPath: asrConfig.localModelPath
        )
    }

    private func fallbackRewriteConfiguration() -> TextGenerationProviderConfiguration {
        TextGenerationProviderConfiguration(
            profileID: textConfig.keyRef,
            providerType: textConfig.providerType,
            providerName: textConfig.providerType.displayName,
            modelName: textConfig.providerType.defaultRewriteModelName,
            baseURL: URL(string: textConfig.providerType.recommendedBaseURLString) ?? URL(string: "https://api.deepseek.com")!
        )
    }

    private func fallbackCLIRewriteConfiguration() -> TextGenerationProviderConfiguration {
        TextGenerationProviderConfiguration(
            profileID: cliTextConfig.keyRef,
            providerType: cliTextConfig.providerType,
            providerName: cliTextConfig.providerType.displayName,
            modelName: cliTextConfig.providerType.defaultRewriteModelName,
            baseURL: URL(string: cliTextConfig.providerType.recommendedBaseURLString) ?? URL(string: "https://api.deepseek.com")!
        )
    }

    private func persistASRConfig() {
        if let data = try? JSONEncoder().encode(asrConfig) {
            defaults.set(data, forKey: defaultsASRConfigKey)
        }
    }

    private func persistTextConfig() {
        if let data = try? JSONEncoder().encode(textConfig) {
            defaults.set(data, forKey: defaultsTextConfigKey)
        }
    }

    private func persistCLITextConfig() {
        if let data = try? JSONEncoder().encode(cliTextConfig) {
            defaults.set(data, forKey: defaultsCLITextConfigKey)
        }
    }

    private func persistFeishuCLIExecutablePathOverride() {
        let normalized = Self.sanitizeCLIExecutablePathOverride(feishuCLIExecutablePathOverride)
        if normalized.isEmpty {
            defaults.removeObject(forKey: defaultsFeishuCLIExecutablePathOverrideKey)
            return
        }
        defaults.set(normalized, forKey: defaultsFeishuCLIExecutablePathOverrideKey)
    }

    private func persistLatestASRTestResult() {
        guard let latestASRTestResult else {
            defaults.removeObject(forKey: defaultsLatestASRTestResultKey)
            return
        }

        if let data = try? JSONEncoder().encode(latestASRTestResult) {
            defaults.set(data, forKey: defaultsLatestASRTestResultKey)
        }
    }

    private func persistLatestTextTestResult() {
        guard let latestTextTestResult else {
            defaults.removeObject(forKey: defaultsLatestTextTestResultKey)
            return
        }

        if let data = try? JSONEncoder().encode(latestTextTestResult) {
            defaults.set(data, forKey: defaultsLatestTextTestResultKey)
        }
    }

    private func persistLatestCLITextTestResult() {
        guard let latestCLITextTestResult else {
            defaults.removeObject(forKey: defaultsLatestCLITextTestResultKey)
            return
        }

        if let data = try? JSONEncoder().encode(latestCLITextTestResult) {
            defaults.set(data, forKey: defaultsLatestCLITextTestResultKey)
        }
    }

    private func clearASRTestResult() {
        guard latestASRTestResult != nil else {
            return
        }
        latestASRTestResult = nil
        persistLatestASRTestResult()
    }

    private func clearTextTestResult() {
        guard latestTextTestResult != nil else {
            return
        }
        latestTextTestResult = nil
        persistLatestTextTestResult()
    }

    private func clearCLITextTestResult() {
        guard latestCLITextTestResult != nil else {
            return
        }
        latestCLITextTestResult = nil
        persistLatestCLITextTestResult()
    }

    private func saveAPIKey(
        draft: String,
        keyRef: String,
        roleName: String,
        onSaving: () -> Void = {},
        onSuccess: () -> Void,
        onFailure: (CredentialState, String) -> Void
    ) -> Bool {
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            onFailure(.missing, "\(roleName) API 密钥不能为空。")
            return false
        }

        guard normalized.count >= 12 else {
            onFailure(.failed(nil), "\(roleName) API 密钥长度看起来太短。")
            return false
        }

        do {
            onSaving()
            try credentialStore.saveAPIKey(normalized, for: keyRef)
            let readBack = (try credentialStore.loadAPIKey(for: keyRef) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard readBack == normalized else {
                onFailure(.failed(nil), "\(roleName) API 密钥保存后校验失败，请重试。")
                return false
            }
            onSuccess()
            return true
        } catch ProviderCredentialStoreError.interactionRequired {
            onFailure(.inaccessible, "当前密钥存储不可直接访问，请删除后重新保存。")
            return false
        } catch ProviderCredentialStoreError.invalidCredentialEncoding {
            onFailure(.failed(nil), "已保存的 \(roleName) API 密钥无法解析，请删除后重新保存。")
            return false
        } catch let ProviderCredentialStoreError.unexpectedStatus(status) {
            onFailure(.failed(status), "无法保存 \(roleName) API 密钥（OSStatus \(status)）。")
            return false
        } catch {
            onFailure(.failed(nil), "无法保存 \(roleName) API 密钥：\(error.localizedDescription)")
            return false
        }
    }

    private func clearAPIKey(
        keyRef: String,
        roleName: String,
        onSuccess: () -> Void,
        onFailure: (String) -> Void
    ) -> Bool {
        do {
            try credentialStore.deleteAPIKey(for: keyRef)
            onSuccess()
            return true
        } catch {
            onFailure("无法删除 \(roleName) API 密钥。")
            return false
        }
    }

    private func resolveCredentialState(
        keyRef: String,
        roleName: String,
        allowUserInteraction: Bool,
        onFeedback: (String?) -> Void
    ) -> CredentialState {
        do {
            let contains = try credentialStore.containsAPIKey(
                for: keyRef,
                allowUserInteraction: allowUserInteraction
            )
            onFeedback(nil)
            return contains ? .saved : .missing
        } catch let error as ProviderCredentialStoreError {
            switch error {
            case .interactionRequired:
                onFeedback("当前密钥存储不可直接访问，请在 App 内重新保存一次密钥。")
                return .inaccessible
            case let .unexpectedStatus(status):
                onFeedback("读取\(roleName) API 密钥失败（OSStatus \(status)）。")
                return .failed(status)
            case .invalidCredentialEncoding:
                onFeedback("\(roleName) API 密钥无法解析，请删除后重新保存。")
                return .failed(nil)
            }
        } catch {
            onFeedback("无法读取\(roleName) API 密钥。")
            return .failed(nil)
        }
    }

    private func hasNonEmptyCredential(for keyRef: String) -> Bool {
        let loaded = (try? credentialStore.loadAPIKey(for: keyRef)) ?? nil
        let normalized = loaded?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !normalized.isEmpty
    }

    private func migrateLegacyCredentialsIfNeeded(using migration: LegacyMigration) {
        migrateLegacyCredential(
            oldRef: migration.legacyASRKeyRef,
            newRef: asrConfig.keyRef
        )
        migrateLegacyCredential(
            oldRef: migration.legacyTextKeyRef,
            newRef: textConfig.keyRef
        )
    }

    private func migrateLegacyCredential(oldRef: String?, newRef: String) {
        guard let oldRef, !oldRef.isEmpty, oldRef != newRef else {
            return
        }

        if
            let existing = try? credentialStore.loadAPIKey(for: newRef),
            !existing.isEmpty
        {
            return
        }

        guard
            let legacy = try? credentialStore.loadAPIKey(for: oldRef),
            !legacy.isEmpty
        else {
            return
        }

        try? credentialStore.saveAPIKey(legacy, for: newRef)
    }

    private static func sanitizeASRConfig(_ config: ASRConfig) -> ASRConfig {
        var sanitized = config
        if !sanitized.providerType.allowsCustomBaseURL {
            sanitized.baseURLString = sanitized.providerType.recommendedBaseURLString
        }
        if sanitized.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sanitized.modelName = sanitized.providerType.defaultTranscriptionModelName
        }
        if sanitized.keyRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sanitized.keyRef = defaultASRCredentialKeyRef
        }
        let normalizedModelPath = sanitized.localModelPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.providerType == .localSenseVoice {
            sanitized.localModelPath = (normalizedModelPath?.isEmpty == false)
                ? normalizedModelPath
                : defaultSenseVoiceModelPath
        } else if normalizedModelPath?.isEmpty == true {
            sanitized.localModelPath = nil
        } else {
            sanitized.localModelPath = normalizedModelPath
        }
        return sanitized
    }

    private static func sanitizeTextConfig(_ config: TextConfig) -> TextConfig {
        var sanitized = config
        if !sanitized.providerType.allowsCustomBaseURL {
            sanitized.baseURLString = sanitized.providerType.recommendedBaseURLString
        } else {
            let normalizedBaseURL = normalizedBaseURLString(sanitized.baseURLString)
            if normalizedBaseURL.isEmpty || shouldRepairCompatibleDeepSeekEndpoint(for: sanitized) {
                sanitized.baseURLString = sanitized.providerType.recommendedBaseURLString
            } else {
                sanitized.baseURLString = normalizedBaseURL
            }
        }
        if sanitized.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sanitized.modelName = sanitized.providerType.defaultRewriteModelName
        }
        if sanitized.keyRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sanitized.keyRef = defaultTextCredentialKeyRef
        }
        return sanitized
    }

    private static func sanitizeCLITextConfig(_ config: TextConfig) -> TextConfig {
        var sanitized = sanitizeTextConfig(config)
        if sanitized.keyRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sanitized.keyRef = defaultCLITextCredentialKeyRef
        }
        return sanitized
    }

    private static func normalizedBaseURLString(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    private static func shouldResetCompatibleBaseURL(
        previousProviderType: ProviderType,
        previousBaseURLString: String
    ) -> Bool {
        guard previousProviderType != .openAICompatible else {
            return normalizedBaseURLString(previousBaseURLString).isEmpty
        }

        let previousFixedBaseURL = normalizedBaseURLString(
            previousProviderType.recommendedBaseURLString
        )
        let currentBaseURL = normalizedBaseURLString(previousBaseURLString)
        return currentBaseURL.isEmpty || currentBaseURL == previousFixedBaseURL
    }

    private static func shouldRepairCompatibleDeepSeekEndpoint(for config: TextConfig) -> Bool {
        guard config.providerType == .openAICompatible else {
            return false
        }

        let normalizedBaseURL = normalizedBaseURLString(config.baseURLString)
        let openAIBaseURL = normalizedBaseURLString(ProviderType.openAI.recommendedBaseURLString)
        guard normalizedBaseURL == openAIBaseURL else {
            return false
        }

        let normalizedModel = config.modelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedModel.hasPrefix("deepseek")
    }

    private static func sanitizeCLIExecutablePathOverride(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeASRConfig(from data: Data?) -> ASRConfig? {
        guard
            let data,
            let decoded = try? JSONDecoder().decode(ASRConfig.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    private static func decodeTextConfig(from data: Data?) -> TextConfig? {
        guard
            let data,
            let decoded = try? JSONDecoder().decode(TextConfig.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    private static func decodeConnectionTestResult(from data: Data?) -> ConnectionTestResult? {
        guard
            let data,
            let decoded = try? JSONDecoder().decode(ConnectionTestResult.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    private static func defaultASRConfig() -> ASRConfig {
        ASRConfig(
            providerType: .dashScopeQwenASR,
            baseURLString: "https://dashscope.aliyuncs.com",
            modelName: ProviderType.dashScopeQwenASR.defaultTranscriptionModelName,
            keyRef: defaultASRCredentialKeyRef
        )
    }

    private static func defaultTextConfig() -> TextConfig {
        TextConfig(
            providerType: .openAICompatible,
            baseURLString: ProviderType.openAICompatible.recommendedBaseURLString,
            modelName: ProviderType.openAICompatible.defaultRewriteModelName,
            keyRef: defaultTextCredentialKeyRef
        )
    }

    private static func defaultCLITextConfig() -> TextConfig {
        TextConfig(
            providerType: .openAICompatible,
            baseURLString: ProviderType.openAICompatible.recommendedBaseURLString,
            modelName: ProviderType.openAICompatible.defaultRewriteModelName,
            keyRef: defaultCLITextCredentialKeyRef
        )
    }

    private struct LegacyProviderProfile: Codable {
        let id: String
        let type: ProviderType
        let isEnabled: Bool
        let baseURLString: String
        let transcriptionModelName: String
        let rewriteModelName: String
    }

    private struct LegacyMigration {
        let asrConfig: ASRConfig
        let textConfig: TextConfig
        let legacyASRKeyRef: String?
        let legacyTextKeyRef: String?
    }

    private static func migrateLegacyConfiguration(defaults: UserDefaults) -> LegacyMigration {
        let fallbackASR = defaultASRConfig()
        let fallbackText = defaultTextConfig()
        guard
            let data = defaults.data(forKey: "providers.profiles.v1"),
            let profiles = try? JSONDecoder().decode([LegacyProviderProfile].self, from: data),
            !profiles.isEmpty
        else {
            let asrModel = defaults.string(forKey: "speech.provider.model")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let textModel = defaults.string(forKey: "rewrite.provider.model")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let asr = ASRConfig(
                providerType: fallbackASR.providerType,
                baseURLString: fallbackASR.baseURLString,
                modelName: (asrModel?.isEmpty == false) ? asrModel : fallbackASR.modelName,
                keyRef: defaultASRCredentialKeyRef
            )
            let text = TextConfig(
                providerType: fallbackText.providerType,
                baseURLString: fallbackText.baseURLString,
                modelName: (textModel?.isEmpty == false) ? textModel : fallbackText.modelName,
                keyRef: defaultTextCredentialKeyRef
            )
            return LegacyMigration(
                asrConfig: asr,
                textConfig: text,
                legacyASRKeyRef: nil,
                legacyTextKeyRef: nil
            )
        }

        let enabledProfiles = profiles.filter(\.isEnabled)
        let pool = enabledProfiles.isEmpty ? profiles : enabledProfiles

        let selectedASRID = defaults.string(forKey: "providers.transcription.profile.id")
        let selectedTextID = defaults.string(forKey: "providers.rewrite.profile.id")

        let asrProfile = pool.first(where: { $0.id == selectedASRID }) ?? pool[0]
        let textProfile = pool.first(where: { $0.id == selectedTextID }) ?? asrProfile

        let asrBaseURL = asrProfile.type.fixedBaseURL?.absoluteString ?? asrProfile.baseURLString
        let textBaseURL = textProfile.type.fixedBaseURL?.absoluteString ?? textProfile.baseURLString

        let asr = ASRConfig(
            providerType: asrProfile.type,
            baseURLString: asrBaseURL,
            modelName: asrProfile.transcriptionModelName,
            keyRef: defaultASRCredentialKeyRef
        )
        let text = TextConfig(
            providerType: textProfile.type,
            baseURLString: textBaseURL,
            modelName: textProfile.rewriteModelName,
            keyRef: defaultTextCredentialKeyRef
        )

        return LegacyMigration(
            asrConfig: asr,
            textConfig: text,
            legacyASRKeyRef: asrProfile.id,
            legacyTextKeyRef: textProfile.id
        )
    }
}

protocol SpeechProvider {
    var providerName: String { get }
}

struct PlaceholderSpeechProvider: SpeechProvider {
    let providerName: String = "用户自填云端服务商 Key"
}

enum ConnectionTestStatus: String, Equatable, Codable {
    case success
    case failure
}

struct ConnectionTestResult: Equatable, Codable {
    let status: ConnectionTestStatus
    let message: String
    let hint: String
    let timestamp: Date
    let httpStatus: Int?

    static func success(
        message: String,
        hint: String = "配置可用。",
        httpStatus: Int? = 200
    ) -> ConnectionTestResult {
        ConnectionTestResult(
            status: .success,
            message: message,
            hint: hint,
            timestamp: Date(),
            httpStatus: httpStatus
        )
    }

    static func failure(
        message: String,
        hint: String,
        httpStatus: Int? = nil
    ) -> ConnectionTestResult {
        ConnectionTestResult(
            status: .failure,
            message: message,
            hint: hint,
            timestamp: Date(),
            httpStatus: httpStatus
        )
    }
}

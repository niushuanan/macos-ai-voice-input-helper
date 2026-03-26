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
        }
    }

    @Published var textConfig: TextConfig {
        didSet {
            persistTextConfig()
        }
    }

    @Published var asrAPIKeyDraft: String = ""
    @Published var textAPIKeyDraft: String = ""

    @Published private(set) var asrCredentialState: CredentialState = .unknown
    @Published private(set) var textCredentialState: CredentialState = .unknown
    @Published private(set) var asrFeedbackMessage: String?
    @Published private(set) var textFeedbackMessage: String?
    @Published private(set) var latestASRTestResult: ConnectionTestResult?
    @Published private(set) var latestTextTestResult: ConnectionTestResult?

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

    var configuration: SpeechProviderConfiguration {
        transcriptionConfiguration ?? fallbackTranscriptionConfiguration()
    }

    var rewriteConfiguration: TextGenerationProviderConfiguration {
        resolvedRewriteConfiguration() ?? fallbackRewriteConfiguration()
    }

    var transcriptionConfiguration: SpeechProviderConfiguration? {
        resolvedTranscriptionConfiguration()
    }

    var credentialState: CredentialState {
        asrCredentialState
    }

    private let defaults: UserDefaults
    private let credentialStore: ProviderCredentialStore
    private let defaultsASRConfigKey = "providers.asr.config.v2"
    private let defaultsTextConfigKey = "providers.text.config.v2"
    private let defaultsLatestASRTestResultKey = "providers.asr.test.result.v1"
    private let defaultsLatestTextTestResultKey = "providers.text.test.result.v1"

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

        let legacyMigration = Self.migrateLegacyConfiguration(defaults: defaults)

        self.asrConfig = Self.sanitizeASRConfig(
            decodedASRConfig ?? legacyMigration.asrConfig
        )
        self.textConfig = Self.sanitizeTextConfig(
            decodedTextConfig ?? legacyMigration.textConfig
        )
        self.latestASRTestResult = Self.decodeConnectionTestResult(
            from: defaults.data(forKey: defaultsLatestASRTestResultKey)
        )
        self.latestTextTestResult = Self.decodeConnectionTestResult(
            from: defaults.data(forKey: defaultsLatestTextTestResultKey)
        )

        persistASRConfig()
        persistTextConfig()
        migrateLegacyCredentialsIfNeeded(using: legacyMigration)
        refreshCredentialState(allowUserInteraction: false)
    }

    func refreshCredentialState(allowUserInteraction: Bool = false) {
        asrCredentialState = resolveCredentialState(
            keyRef: asrConfig.keyRef,
            roleName: "语音识别",
            allowUserInteraction: allowUserInteraction
        )
        textCredentialState = resolveCredentialState(
            keyRef: textConfig.keyRef,
            roleName: "文本模型",
            allowUserInteraction: allowUserInteraction
        )
    }

    @discardableResult
    func saveASRAPIKeyDraft() -> Bool {
        saveAPIKey(
            draft: asrAPIKeyDraft,
            keyRef: asrConfig.keyRef,
            roleName: "语音识别",
            onSuccess: { [weak self] in
                self?.asrAPIKeyDraft = ""
                self?.asrCredentialState = .saved
                self?.asrFeedbackMessage = "语音识别 API 密钥已保存。"
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
            onSuccess: { [weak self] in
                self?.textAPIKeyDraft = ""
                self?.textCredentialState = .saved
                self?.textFeedbackMessage = "文本模型 API 密钥已保存。"
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
            },
            onFailure: { [weak self] message in
                self?.textFeedbackMessage = message
            }
        )
    }

    func loadAPIKeyForTranscriptionProvider() throws -> String? {
        try credentialStore.loadAPIKey(for: asrConfig.keyRef)
    }

    func loadAPIKeyForRewriteProvider() throws -> String? {
        try credentialStore.loadAPIKey(for: textConfig.keyRef)
    }

    func loadAPIKeyForActiveProvider() throws -> String? {
        try credentialStore.loadAPIKey(for: asrConfig.keyRef)
    }

    func updateASRProviderType(_ type: ProviderType) {
        guard type.supportsTranscription else {
            return
        }
        asrConfig.providerType = type
        if !type.allowsCustomBaseURL {
            asrConfig.baseURLString = type.fixedBaseURL?.absoluteString ?? ""
        }
        asrConfig.modelName = type.defaultTranscriptionModelName
        if type == .localSenseVoice {
            let currentPath = asrConfig.localModelPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            asrConfig.localModelPath = (currentPath?.isEmpty == false) ? currentPath : defaultSenseVoiceModelPath
        }
    }

    func updateTextProviderType(_ type: ProviderType) {
        guard type.supportsRewrite else {
            return
        }
        textConfig.providerType = type
        if !type.allowsCustomBaseURL {
            textConfig.baseURLString = type.fixedBaseURL?.absoluteString ?? ""
        }
        textConfig.modelName = type.defaultRewriteModelName
    }

    func updateASRBaseURL(_ value: String) {
        asrConfig.baseURLString = value
    }

    func updateTextBaseURL(_ value: String) {
        textConfig.baseURLString = value
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

    func recordASRTestResult(_ result: ConnectionTestResult) {
        latestASRTestResult = result
        persistLatestASRTestResult()
    }

    func recordTextTestResult(_ result: ConnectionTestResult) {
        latestTextTestResult = result
        persistLatestTextTestResult()
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
            baseURL: textConfig.providerType.fixedBaseURL ?? URL(string: "https://api.openai.com")!
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

    private func saveAPIKey(
        draft: String,
        keyRef: String,
        roleName: String,
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
            if roleName == "语音识别" {
                asrCredentialState = .saving
            } else {
                textCredentialState = .saving
            }
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
        allowUserInteraction: Bool
    ) -> CredentialState {
        do {
            let contains = try credentialStore.containsAPIKey(
                for: keyRef,
                allowUserInteraction: allowUserInteraction
            )
            if roleName == "语音识别" {
                asrFeedbackMessage = nil
            } else {
                textFeedbackMessage = nil
            }
            return contains ? .saved : .missing
        } catch let error as ProviderCredentialStoreError {
            switch error {
            case .interactionRequired:
                if roleName == "语音识别" {
                    asrFeedbackMessage = "当前密钥存储不可直接访问，请在 App 内重新保存一次密钥。"
                } else {
                    textFeedbackMessage = "当前密钥存储不可直接访问，请在 App 内重新保存一次密钥。"
                }
                return .inaccessible
            case let .unexpectedStatus(status):
                if roleName == "语音识别" {
                    asrFeedbackMessage = "读取语音识别 API 密钥失败（OSStatus \(status)）。"
                } else {
                    textFeedbackMessage = "读取文本模型 API 密钥失败（OSStatus \(status)）。"
                }
                return .failed(status)
            case .invalidCredentialEncoding:
                if roleName == "语音识别" {
                    asrFeedbackMessage = "语音识别 API 密钥无法解析，请删除后重新保存。"
                } else {
                    textFeedbackMessage = "文本模型 API 密钥无法解析，请删除后重新保存。"
                }
                return .failed(nil)
            }
        } catch {
            if roleName == "语音识别" {
                asrFeedbackMessage = "无法读取语音识别 API 密钥。"
            } else {
                textFeedbackMessage = "无法读取文本模型 API 密钥。"
            }
            return .failed(nil)
        }
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
            sanitized.baseURLString = sanitized.providerType.fixedBaseURL?.absoluteString ?? ""
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
            sanitized.baseURLString = sanitized.providerType.fixedBaseURL?.absoluteString ?? ""
        }
        if sanitized.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sanitized.modelName = sanitized.providerType.defaultRewriteModelName
        }
        if sanitized.keyRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sanitized.keyRef = defaultTextCredentialKeyRef
        }
        return sanitized
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
            baseURLString: "https://api.deepseek.com",
            modelName: "deepseek-chat",
            keyRef: defaultTextCredentialKeyRef
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

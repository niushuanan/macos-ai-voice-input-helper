import Combine
import Foundation
import Security

private let defaultASRCredentialKeyRef = "asr.primary"
private let defaultTextCredentialKeyRef = "text.primary"
let defaultSenseVoiceModelPath =
    "~/Library/Application Support/Shandianshuo/models/sensevoice-small"

enum ProviderType: String, CaseIterable, Codable, Identifiable {
    case openAI
    case openAICompatible
    case dashScopeQwenASR
    case localSenseVoice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI（官方）"
        case .openAICompatible:
            return "OpenAI 兼容"
        case .dashScopeQwenASR:
            return "阿里云 Qwen ASR"
        case .localSenseVoice:
            return "本地 SenseVoice（实验）"
        }
    }

    var shortLabel: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .openAICompatible:
            return "兼容"
        case .dashScopeQwenASR:
            return "Qwen"
        case .localSenseVoice:
            return "本地"
        }
    }

    var defaultTranscriptionModelName: String {
        switch self {
        case .dashScopeQwenASR:
            return "qwen3-asr-flash"
        case .localSenseVoice:
            return "sensevoice-small"
        case .openAI, .openAICompatible:
            return "whisper-1"
        }
    }

    var defaultRewriteModelName: String {
        switch self {
        case .openAI:
            return "gpt-4o-mini"
        case .openAICompatible:
            return "deepseek-chat"
        case .dashScopeQwenASR:
            return "deepseek-chat"
        case .localSenseVoice:
            return "deepseek-chat"
        }
    }

    var supportsTranscription: Bool {
        switch self {
        case .openAI, .openAICompatible, .dashScopeQwenASR, .localSenseVoice:
            return true
        }
    }

    var supportsRewrite: Bool {
        switch self {
        case .openAI, .openAICompatible:
            return true
        case .dashScopeQwenASR, .localSenseVoice:
            return false
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .openAI, .openAICompatible, .dashScopeQwenASR:
            return true
        case .localSenseVoice:
            return false
        }
    }

    var allowsCustomBaseURL: Bool {
        self == .openAICompatible
    }

    var fixedBaseURL: URL? {
        switch self {
        case .openAI:
            return URL(string: "https://api.openai.com")
        case .openAICompatible:
            return nil
        case .dashScopeQwenASR:
            return URL(string: "https://dashscope.aliyuncs.com")
        case .localSenseVoice:
            return URL(string: "https://local.sensevoice")
        }
    }
}

struct ASRConfig: Codable, Equatable {
    var providerType: ProviderType
    var baseURLString: String
    var modelName: String
    var keyRef: String
    var localModelPath: String?

    init(
        providerType: ProviderType = .openAI,
        baseURLString: String? = nil,
        modelName: String? = nil,
        keyRef: String = defaultASRCredentialKeyRef,
        localModelPath: String? = nil
    ) {
        self.providerType = providerType
        self.baseURLString = baseURLString ?? providerType.fixedBaseURL?.absoluteString ?? ""
        self.modelName = modelName ?? providerType.defaultTranscriptionModelName
        self.keyRef = keyRef
        self.localModelPath = localModelPath
    }
}

struct TextConfig: Codable, Equatable {
    var providerType: ProviderType
    var baseURLString: String
    var modelName: String
    var keyRef: String

    init(
        providerType: ProviderType = .openAI,
        baseURLString: String? = nil,
        modelName: String? = nil,
        keyRef: String = defaultTextCredentialKeyRef
    ) {
        self.providerType = providerType
        self.baseURLString = baseURLString ?? providerType.fixedBaseURL?.absoluteString ?? ""
        self.modelName = modelName ?? providerType.defaultRewriteModelName
        self.keyRef = keyRef
    }
}

struct SpeechProviderConfiguration: Equatable {
    let profileID: String
    let providerType: ProviderType
    let providerName: String
    let modelName: String
    let baseURL: URL
    let localModelPath: String?

    init(
        profileID: String,
        providerType: ProviderType,
        providerName: String,
        modelName: String,
        baseURL: URL,
        localModelPath: String? = nil
    ) {
        self.profileID = profileID
        self.providerType = providerType
        self.providerName = providerName
        self.modelName = modelName
        self.baseURL = baseURL
        self.localModelPath = localModelPath
    }
}

struct TextGenerationProviderConfiguration: Equatable {
    let profileID: String
    let providerType: ProviderType
    let providerName: String
    let modelName: String
    let baseURL: URL
}

struct SpeechTranscriptionRequest {
    let clip: RecordedAudioClip
    let lane: InputLane
    let contextSummary: String
}

struct SpeechTranscriptionResult: Equatable {
    let providerType: ProviderType
    let providerName: String
    let modelName: String
    let transcript: String
}

enum SpeechTranscriptionError: LocalizedError {
    case missingAPIKey(providerName: String)
    case audioFormatUnsupported(fileExtension: String)
    case networkFailure(description: String)
    case providerFailure(description: String)
    case invalidResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .missingAPIKey(providerName):
            return "\(providerName) 缺少 API 密钥。"
        case let .audioFormatUnsupported(fileExtension):
            return "该服务商不支持音频格式 \(fileExtension)。"
        case let .networkFailure(description):
            return "网络请求失败：\(description)"
        case let .providerFailure(description):
            return "服务商返回异常：\(description)"
        case .invalidResponse:
            return "服务商返回内容无法解析。"
        case .cancelled:
            return "转写请求已取消。"
        }
    }
}

protocol SpeechTranscriptionProvider {
    var supportedProviderTypes: [ProviderType] { get }
    func transcribe(
        request: SpeechTranscriptionRequest,
        configuration: SpeechProviderConfiguration,
        apiKey: String
    ) async throws -> SpeechTranscriptionResult
}

enum ProviderCredentialStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidCredentialEncoding
    case interactionRequired

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return "钥匙串操作失败，状态码：\(status)。"
        case .invalidCredentialEncoding:
            return "已存凭证无法解析。"
        case .interactionRequired:
            return "钥匙串访问需要用户交互。"
        }
    }
}

protocol ProviderCredentialStore {
    func loadAPIKey(for profileID: String) throws -> String?
    func saveAPIKey(_ value: String, for profileID: String) throws
    func deleteAPIKey(for profileID: String) throws
    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool
}

enum ProviderConfigurationValidator {
    static func validationMessage(
        providerType: ProviderType,
        baseURLString: String,
        modelName: String
    ) -> String? {
        let normalizedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedModel.isEmpty {
            return "模型名不能为空。"
        }

        if normalizedModel.count > 80 {
            return "模型名过长。"
        }

        if normalizedModel.contains(where: \.isWhitespace) {
            return "模型名不能带空格。"
        }

        if resolvedBaseURL(providerType: providerType, baseURLString: baseURLString) == nil {
            return "接口地址（Base URL）无效。"
        }

        return nil
    }

    static func resolvedBaseURL(
        providerType: ProviderType,
        baseURLString: String
    ) -> URL? {
        if let fixedURL = providerType.fixedBaseURL {
            return fixedURL
        }

        let normalized = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }

        guard
            let url = URL(string: normalized),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            return nil
        }

        return url
    }
}

@MainActor
final class ProviderSettingsStore: ObservableObject {
    enum CredentialState: Equatable {
        case unknown
        case missing
        case saved
        case needsRebind
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
    private let defaultsKeychainRebindRequiredKey = "providers.keychain.rebind.required"

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
        if defaults.bool(forKey: defaultsKeychainRebindRequiredKey) {
            asrCredentialState = .needsRebind
            textCredentialState = .needsRebind
            asrFeedbackMessage = "检测到历史钥匙串权限设置，请重新保存语音识别 API 密钥。"
            textFeedbackMessage = "检测到历史钥匙串权限设置，请重新保存文本模型 API 密钥。"
            return
        }

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
                self?.asrFeedbackMessage = "语音识别 API 密钥已写入钥匙串。"
                self?.clearKeychainRebindFlagIfPossible(roleKeyRef: self?.asrConfig.keyRef ?? "")
            },
            onFailure: { [weak self] message in
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
                self?.textFeedbackMessage = "文本模型 API 密钥已写入钥匙串。"
                self?.clearKeychainRebindFlagIfPossible(roleKeyRef: self?.textConfig.keyRef ?? "")
            },
            onFailure: { [weak self] message in
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
        onFailure: (String) -> Void
    ) -> Bool {
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            onFailure("\(roleName) API 密钥不能为空。")
            return false
        }

        guard normalized.count >= 12 else {
            onFailure("\(roleName) API 密钥长度看起来太短。")
            return false
        }

        do {
            try credentialStore.saveAPIKey(normalized, for: keyRef)
            onSuccess()
            return true
        } catch {
            onFailure("无法把 \(roleName) API 密钥写入钥匙串。")
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
                    asrFeedbackMessage = "检测到钥匙串访问需要交互，请重新保存一次语音识别 API 密钥。"
                } else {
                    textFeedbackMessage = "检测到钥匙串访问需要交互，请重新保存一次文本模型 API 密钥。"
                }
                return .needsRebind
            default:
                if roleName == "语音识别" {
                    asrFeedbackMessage = "无法从钥匙串读取语音识别 API 密钥。"
                } else {
                    textFeedbackMessage = "无法从钥匙串读取文本模型 API 密钥。"
                }
                return .unknown
            }
        } catch {
            if roleName == "语音识别" {
                asrFeedbackMessage = "无法从钥匙串读取语音识别 API 密钥。"
            } else {
                textFeedbackMessage = "无法从钥匙串读取文本模型 API 密钥。"
            }
            return .unknown
        }
    }

    private func clearKeychainRebindFlagIfPossible(roleKeyRef: String) {
        guard defaults.bool(forKey: defaultsKeychainRebindRequiredKey) else {
            return
        }
        let asrReady = (asrCredentialState == .saved) || roleKeyRef == asrConfig.keyRef
        let textReady = (textCredentialState == .saved) || roleKeyRef == textConfig.keyRef
        guard asrReady && textReady else {
            return
        }
        defaults.set(false, forKey: defaultsKeychainRebindRequiredKey)
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

struct ASRConnectionTester {
    private let session: URLSession
    private let credentialStore: ProviderCredentialStore

    init(
        session: URLSession = .shared,
        credentialStore: ProviderCredentialStore
    ) {
        self.session = session
        self.credentialStore = credentialStore
    }

    func test(config: ASRConfig) async -> ConnectionTestResult {
        if let validationMessage = ProviderConfigurationValidator.validationMessage(
            providerType: config.providerType,
            baseURLString: config.baseURLString,
            modelName: config.modelName
        ) {
            return .failure(
                message: "语音识别配置校验失败：\(validationMessage)",
                hint: "请检查接口地址和模型名。"
            )
        }

        let apiKey: String
        if config.providerType.requiresAPIKey {
            do {
                let loaded = (try credentialStore.loadAPIKey(for: config.keyRef) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !loaded.isEmpty else {
                    return .failure(
                        message: "语音识别 API 密钥为空。",
                        hint: "请先填写并保存 API 密钥，再点测试。"
                    )
                }
                apiKey = loaded
            } catch {
                return .failure(
                    message: "无法读取语音识别 API 密钥：\(error.localizedDescription)",
                    hint: "请重新保存密钥后重试。"
                )
            }
        } else {
            apiKey = ""
        }

        guard
            let baseURL = ProviderConfigurationValidator.resolvedBaseURL(
                providerType: config.providerType,
                baseURLString: config.baseURLString
            )
        else {
            return .failure(
                message: "语音识别接口地址无效。",
                hint: "请填写以 http 或 https 开头的地址。"
            )
        }

        let audioData = DiagnosticAudioSample.makeWaveData()
        switch config.providerType {
        case .dashScopeQwenASR:
            return await testDashScope(
                config: config,
                baseURL: baseURL,
                apiKey: apiKey,
                audioData: audioData
            )
        case .localSenseVoice:
            return LocalSenseVoiceHealthChecker.check(config: config)
        case .openAI, .openAICompatible:
            return await testOpenAICompatible(
                config: config,
                baseURL: baseURL,
                apiKey: apiKey,
                audioData: audioData
            )
        }
    }

    private func testOpenAICompatible(
        config: ASRConfig,
        baseURL: URL,
        apiKey: String,
        audioData: Data
    ) async -> ConnectionTestResult {
        let endpoint = OpenAIEndpointResolver.transcriptionURL(baseURL: baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            modelName: config.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            audioData: audioData
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(
                    message: "语音识别测试失败：无效 HTTP 响应。",
                    hint: "请检查接口地址是否正确。"
                )
            }

            if (200..<300).contains(http.statusCode) {
                let transcript = Self.parseASRTranscript(from: data)
                if transcript.isEmpty {
                    return .failure(
                        message: "语音识别接口可达，但返回内容无法解析。",
                        hint: "请核对接口是否兼容 OpenAI `/v1/audio/transcriptions`。",
                        httpStatus: http.statusCode
                    )
                }
                return .success(
                    message: "语音识别测试成功：\(transcript)",
                    hint: "接口、模型与密钥均可用。",
                    httpStatus: http.statusCode
                )
            }

            let detail = Self.parseProviderError(from: data)
            return .failure(
                message: "语音识别测试失败：HTTP \(http.statusCode) \(detail)",
                hint: ConnectionTestHintResolver.hint(for: http.statusCode),
                httpStatus: http.statusCode
            )
        } catch let urlError as URLError {
            return .failure(
                message: "语音识别测试失败：网络异常 \(urlError.localizedDescription)",
                hint: "请检查网络、代理或接口地址是否可访问。"
            )
        } catch {
            return .failure(
                message: "语音识别测试失败：\(error.localizedDescription)",
                hint: "请稍后重试，如反复失败请检查地址与密钥。"
            )
        }
    }

    private func testDashScope(
        config: ASRConfig,
        baseURL: URL,
        apiKey: String,
        audioData: Data
    ) async -> ConnectionTestResult {
        let endpoint = DashScopeEndpointResolver.generationURL(baseURL: baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(
                DashScopeASRPayload(
                    model: config.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                    input: .init(
                        messages: [
                            .init(role: "system", content: [.text("")]),
                            .init(
                                role: "user",
                                content: [
                                    .audio("data:audio/wav;base64,\(audioData.base64EncodedString())")
                                ]
                            )
                        ]
                    ),
                    parameters: .init(
                        resultFormat: "message",
                        asrOptions: .init(enableITN: false)
                    )
                )
            )
        } catch {
            return .failure(
                message: "语音识别测试失败：请求编码异常。",
                hint: "请检查模型名后重试。"
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(
                    message: "语音识别测试失败：无效 HTTP 响应。",
                    hint: "请检查接口地址是否正确。"
                )
            }

            if (200..<300).contains(http.statusCode) {
                let transcript = Self.parseDashScopeTranscript(from: data)
                if transcript.isEmpty {
                    if let businessError = DashScopeResponseParser.businessError(from: data) {
                        return .failure(
                            message: "语音识别测试失败：\(businessError.displayMessage)",
                            hint: Self.hintForDashScopeBusinessError(businessError),
                            httpStatus: http.statusCode
                        )
                    }
                    return .failure(
                        message: "语音识别接口可达，但返回内容无法解析。",
                        hint: "请确认模型名可用，并检查返回格式是否为 message。",
                        httpStatus: http.statusCode
                    )
                }
                return .success(
                    message: "语音识别测试成功：\(transcript)",
                    hint: "接口、模型与密钥均可用。",
                    httpStatus: http.statusCode
                )
            }

            let detail = Self.parseProviderError(from: data)
            return .failure(
                message: "语音识别测试失败：HTTP \(http.statusCode) \(detail)",
                hint: ConnectionTestHintResolver.hint(for: http.statusCode),
                httpStatus: http.statusCode
            )
        } catch let urlError as URLError {
            return .failure(
                message: "语音识别测试失败：网络异常 \(urlError.localizedDescription)",
                hint: "请检查网络、代理或接口地址是否可访问。"
            )
        } catch {
            return .failure(
                message: "语音识别测试失败：\(error.localizedDescription)",
                hint: "请稍后重试，如反复失败请检查地址与密钥。"
            )
        }
    }

    private static func multipartBody(
        boundary: String,
        modelName: String,
        audioData: Data
    ) -> Data {
        var body = Data()
        body.appendUTF8Bytes("--\(boundary)\r\n")
        body.appendUTF8Bytes("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendUTF8Bytes("\(modelName)\r\n")
        body.appendUTF8Bytes("--\(boundary)\r\n")
        body.appendUTF8Bytes("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.appendUTF8Bytes("json\r\n")
        body.appendUTF8Bytes("--\(boundary)\r\n")
        body.appendUTF8Bytes("Content-Disposition: form-data; name=\"file\"; filename=\"pulse-test.wav\"\r\n")
        body.appendUTF8Bytes("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.appendUTF8Bytes("\r\n")
        body.appendUTF8Bytes("--\(boundary)--\r\n")
        return body
    }

    private static func parseASRTranscript(from data: Data) -> String {
        if
            let payload = try? JSONDecoder().decode(ConnectionTestTranscriptionPayload.self, from: data),
            !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func parseDashScopeTranscript(from data: Data) -> String {
        DashScopeResponseParser.transcript(from: data)
    }

    private static func hintForDashScopeBusinessError(_ error: DashScopeBusinessError) -> String {
        let probe = "\(error.code ?? "") \(error.message)".lowercased()
        if probe.contains("api key") || probe.contains("accesskey") || probe.contains("token") || probe.contains("密钥") {
            return "请检查 API 密钥是否正确、是否仍有效。"
        }
        if probe.contains("model") || probe.contains("模型") {
            return "请确认模型名与当前账号可用模型一致。"
        }
        if probe.contains("quota") || probe.contains("余额") || probe.contains("frequency") || probe.contains("rate") || probe.contains("429") {
            return "请检查额度与频率限制，稍后重试。"
        }
        if probe.contains("network") || probe.contains("timeout") || probe.contains("连接") {
            return "请检查网络、代理以及接口地址可达性。"
        }
        return "请检查模型名、密钥、额度与网络后重试。"
    }

    static func parseProviderError(from data: Data) -> String {
        if let businessError = DashScopeResponseParser.businessError(from: data) {
            return redactSensitiveText(businessError.displayMessage)
        }

        if
            let payload = try? JSONDecoder().decode(ConnectionTestErrorEnvelope.self, from: data),
            let message = payload.error.message?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        {
            return redactSensitiveText(message)
        }

        if
            let payload = try? JSONDecoder().decode(DashScopeSimpleErrorEnvelope.self, from: data),
            let message = payload.message?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        {
            return redactSensitiveText(message)
        }

        let fallback = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !fallback.isEmpty else {
            return "无错误详情"
        }
        return redactSensitiveText(fallback)
    }

    static func redactSensitiveText(_ text: String) -> String {
        var output = text
        output = replaceRegex(
            pattern: #"(?i)(Authorization\s*:\s*Bearer\s+)[A-Za-z0-9._\-]+"#,
            template: "$1[REDACTED]",
            in: output
        )
        output = replaceRegex(
            pattern: #"\bBearer\s+[A-Za-z0-9._\-]{20,}\b"#,
            template: "Bearer [REDACTED]",
            in: output
        )
        output = replaceRegex(
            pattern: #"\bsk-[A-Za-z0-9]{10,}\b"#,
            template: "sk-[REDACTED]",
            in: output
        )
        return output
    }

    private static func replaceRegex(
        pattern: String,
        template: String,
        in text: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}

struct TextConnectionTester {
    private let session: URLSession
    private let credentialStore: ProviderCredentialStore

    init(
        session: URLSession = .shared,
        credentialStore: ProviderCredentialStore
    ) {
        self.session = session
        self.credentialStore = credentialStore
    }

    func test(config: TextConfig) async -> ConnectionTestResult {
        if let validationMessage = ProviderConfigurationValidator.validationMessage(
            providerType: config.providerType,
            baseURLString: config.baseURLString,
            modelName: config.modelName
        ) {
            return .failure(
                message: "文本模型配置校验失败：\(validationMessage)",
                hint: "请检查接口地址和模型名。"
            )
        }

        let apiKey: String
        do {
            let loaded = (try credentialStore.loadAPIKey(for: config.keyRef) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !loaded.isEmpty else {
                return .failure(
                    message: "文本模型 API 密钥为空。",
                    hint: "请先填写并保存 API 密钥，再点测试。"
                )
            }
            apiKey = loaded
        } catch {
            return .failure(
                message: "无法读取文本模型 API 密钥：\(error.localizedDescription)",
                hint: "请重新保存密钥后重试。"
            )
        }

        guard
            let baseURL = ProviderConfigurationValidator.resolvedBaseURL(
                providerType: config.providerType,
                baseURLString: config.baseURLString
            )
        else {
            return .failure(
                message: "文本模型接口地址无效。",
                hint: "请填写以 http 或 https 开头的地址。"
            )
        }

        let endpoint = OpenAIEndpointResolver.chatCompletionsURL(baseURL: baseURL)
        let payload = TextConnectionPayload(
            model: config.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: [
                .init(role: "system", content: "你是连接测试助手。"),
                .init(role: "user", content: "请只回复“连接正常”。")
            ]
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            return .failure(
                message: "文本模型测试失败：请求编码异常。",
                hint: "请检查模型名后重试。"
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(
                    message: "文本模型测试失败：无效 HTTP 响应。",
                    hint: "请检查接口地址是否正确。"
                )
            }

            if (200..<300).contains(http.statusCode) {
                guard let output = Self.parseTextOutput(from: data) else {
                    return .failure(
                        message: "文本模型接口可达，但返回内容无法解析。",
                        hint: "请确认接口兼容 OpenAI `/v1/chat/completions`。",
                        httpStatus: http.statusCode
                    )
                }
                return .success(
                    message: "文本模型测试成功：\(output)",
                    hint: "接口、模型与密钥均可用。",
                    httpStatus: http.statusCode
                )
            }

            let detail = ASRConnectionTester.parseProviderError(from: data)
            return .failure(
                message: "文本模型测试失败：HTTP \(http.statusCode) \(detail)",
                hint: ConnectionTestHintResolver.hint(for: http.statusCode),
                httpStatus: http.statusCode
            )
        } catch let urlError as URLError {
            return .failure(
                message: "文本模型测试失败：网络异常 \(urlError.localizedDescription)",
                hint: "请检查网络、代理或接口地址是否可访问。"
            )
        } catch {
            return .failure(
                message: "文本模型测试失败：\(error.localizedDescription)",
                hint: "请稍后重试，如反复失败请检查地址与密钥。"
            )
        }
    }

    private static func parseTextOutput(from data: Data) -> String? {
        guard
            let response = try? JSONDecoder().decode(TextConnectionResponse.self, from: data),
            let first = response.choices.first?.message.content
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !first.isEmpty
        else {
            return nil
        }
        return first
    }
}

private enum ConnectionTestHintResolver {
    static func hint(for statusCode: Int) -> String {
        switch statusCode {
        case 401:
            return "密钥无效，请重新粘贴 API 密钥。"
        case 403:
            return "账号权限不足，请确认模型权限或组织策略。"
        case 404:
            return "地址或模型名可能不对，请检查 Base URL 与模型名。"
        case 429:
            return "额度或频率受限，请检查余额或稍后重试。"
        case 500...599:
            return "服务端暂时异常，可稍后重试。"
        default:
            return "请检查密钥、模型名、接口地址与账号额度。"
        }
    }
}

private struct TextConnectionPayload: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
}

private struct TextConnectionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private enum DiagnosticAudioSample {
    static func makeWaveData(
        sampleRate: Int = 16_000,
        duration: Double = 0.6,
        frequency: Double = 440
    ) -> Data {
        if let bundled = bundledSpeechSampleData() {
            return bundled
        }

        let sampleCount = max(1, Int(Double(sampleRate) * duration))
        var pcmData = Data(capacity: sampleCount * MemoryLayout<Int16>.size)
        let amplitude = 0.2

        for index in 0..<sampleCount {
            let angle = 2.0 * Double.pi * frequency * Double(index) / Double(sampleRate)
            let value = Int16(max(-1, min(1, sin(angle) * amplitude)) * Double(Int16.max))
            var littleEndian = value.littleEndian
            pcmData.append(Data(bytes: &littleEndian, count: MemoryLayout<Int16>.size))
        }

        let byteRate = sampleRate * MemoryLayout<Int16>.size
        let blockAlign = MemoryLayout<Int16>.size
        let dataLength = pcmData.count
        let totalLength = 36 + dataLength

        var wave = Data()
        wave.appendUTF8Bytes("RIFF")
        wave.appendUInt32(UInt32(totalLength))
        wave.appendUTF8Bytes("WAVE")
        wave.appendUTF8Bytes("fmt ")
        wave.appendUInt32(16)
        wave.appendUInt16(1)
        wave.appendUInt16(1)
        wave.appendUInt32(UInt32(sampleRate))
        wave.appendUInt32(UInt32(byteRate))
        wave.appendUInt16(UInt16(blockAlign))
        wave.appendUInt16(16)
        wave.appendUTF8Bytes("data")
        wave.appendUInt32(UInt32(dataLength))
        wave.append(pcmData)
        return wave
    }

    private static func bundledSpeechSampleData() -> Data? {
        for bundle in candidateBundles {
            if
                let url = bundle.url(forResource: "diagnostic-voice-zh", withExtension: "wav"),
                let data = try? Data(contentsOf: url),
                data.count > 44
            {
                return data
            }
        }
        return nil
    }

    private static var candidateBundles: [Bundle] {
        [.main, Bundle(for: DiagnosticAudioSampleBundleProbe.self)]
    }
}

private final class DiagnosticAudioSampleBundleProbe: NSObject {}

private struct ConnectionTestTranscriptionPayload: Decodable {
    let text: String
}

private struct ConnectionTestErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let message: String?
    }

    let error: Payload
}

private struct DashScopeSimpleErrorEnvelope: Decodable {
    let message: String?
}

struct DashScopeASRPayload: Encodable {
    struct Input: Encodable {
        let messages: [Message]
    }

    struct Message: Encodable {
        let role: String
        let content: [Content]
    }

    struct Content: Encodable {
        let text: String?
        let audio: String?

        static func text(_ value: String) -> Content {
            Content(text: value, audio: nil)
        }

        static func audio(_ value: String) -> Content {
            Content(text: nil, audio: value)
        }
    }

    struct Parameters: Encodable {
        let resultFormat: String

        struct ASROptions: Encodable {
            let enableITN: Bool

            enum CodingKeys: String, CodingKey {
                case enableITN = "enable_itn"
            }
        }

        let asrOptions: ASROptions

        enum CodingKeys: String, CodingKey {
            case resultFormat = "result_format"
            case asrOptions = "asr_options"
        }
    }

    let model: String
    let input: Input
    let parameters: Parameters
}

struct DashScopeASRResponse: Decodable {
    let output: DashScopeASROutput?
    let choices: [DashScopeASRChoice]?

    struct DashScopeASROutput: Decodable {
        let choices: [DashScopeASRChoice]?
        let text: String?
    }

    struct DashScopeASRChoice: Decodable {
        let message: DashScopeASRMessage?
        let text: String?
    }

    struct DashScopeASRMessage: Decodable {
        let content: DashScopeASRContent
    }

    enum DashScopeASRContent: Decodable {
        case string(String)
        case items([DashScopeASRContentItem])
        case empty

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .string(string)
                return
            }
            if let items = try? container.decode([DashScopeASRContentItem].self) {
                self = .items(items)
                return
            }
            self = .empty
        }
    }

    struct DashScopeASRContentItem: Decodable {
        let text: String?
    }
}

struct DashScopeBusinessError: Equatable {
    let code: String?
    let message: String

    var displayMessage: String {
        if let code, !code.isEmpty {
            return "\(code)：\(message)"
        }
        return message
    }
}

enum DashScopeResponseParser {
    static func transcript(from data: Data) -> String {
        if
            let payload = try? JSONDecoder().decode(DashScopeASRResponse.self, from: data),
            let parsed = transcript(from: payload),
            !parsed.isEmpty
        {
            return parsed
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            return ""
        }

        let fromOutputChoices = parseChoices(
            from: (json["output"] as? [String: Any])?["choices"]
        )
        if !fromOutputChoices.isEmpty {
            return fromOutputChoices.joined(separator: "\n")
        }

        let fromTopChoices = parseChoices(from: json["choices"])
        if !fromTopChoices.isEmpty {
            return fromTopChoices.joined(separator: "\n")
        }

        if
            let output = json["output"] as? [String: Any],
            let outputText = normalizeText(output["text"])
        {
            return outputText
        }

        if let text = normalizeText(json["text"]) {
            return text
        }

        return ""
    }

    static func businessError(from data: Data) -> DashScopeBusinessError? {
        if
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        {
            let directMessage = normalizeText(json["message"])
            let directCode = normalizeText(json["code"])

            if
                let errorObject = json["error"] as? [String: Any],
                let nestedMessage = normalizeText(errorObject["message"])
            {
                let nestedCode = normalizeText(errorObject["code"]) ?? directCode
                return DashScopeBusinessError(code: nestedCode, message: nestedMessage)
            }

            if let directMessage {
                return DashScopeBusinessError(code: directCode, message: directMessage)
            }
        }

        return nil
    }

    private static func transcript(from payload: DashScopeASRResponse) -> String? {
        let outputChoiceText = collectChoiceText(from: payload.output?.choices)
        if !outputChoiceText.isEmpty {
            return outputChoiceText.joined(separator: "\n")
        }

        let topChoiceText = collectChoiceText(from: payload.choices)
        if !topChoiceText.isEmpty {
            return topChoiceText.joined(separator: "\n")
        }

        if let outputText = payload.output?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !outputText.isEmpty {
            return outputText
        }
        return nil
    }

    private static func collectChoiceText(from choices: [DashScopeASRResponse.DashScopeASRChoice]?) -> [String] {
        guard let choices else {
            return []
        }
        return uniqueNonEmpty(
            choices.compactMap { choice in
                if let content = choice.message?.content {
                    switch content {
                    case let .string(text):
                        return text
                    case let .items(items):
                        return items.compactMap(\.text).joined(separator: "\n")
                    case .empty:
                        return choice.text
                    }
                }
                return choice.text
            }
        )
    }

    private static func parseChoices(from value: Any?) -> [String] {
        guard let choices = value as? [[String: Any]] else {
            return []
        }

        var fragments: [String] = []
        for choice in choices {
            if
                let message = choice["message"] as? [String: Any],
                let content = message["content"]
            {
                fragments.append(contentsOf: parseContent(content))
            }
            if let text = normalizeText(choice["text"]) {
                fragments.append(text)
            }
        }
        return uniqueNonEmpty(fragments)
    }

    private static func parseContent(_ value: Any) -> [String] {
        if let text = normalizeText(value) {
            return [text]
        }
        if let items = value as? [[String: Any]] {
            return uniqueNonEmpty(items.compactMap { normalizeText($0["text"]) })
        }
        if let strings = value as? [String] {
            return uniqueNonEmpty(strings)
        }
        return []
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .filter { seen.insert($0).inserted }
    }

    private static func normalizeText(_ value: Any?) -> String? {
        guard let value else {
            return nil
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}

enum DashScopeEndpointResolver {
    static func generationURL(baseURL: URL) -> URL {
        let normalized = baseURL.absoluteURL
        let rawPath = normalized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if rawPath.hasSuffix("api/v1/services/aigc/multimodal-generation/generation") {
            return normalized
        }

        var url = normalized
        if rawPath.hasSuffix("api/v1") {
            url.appendPathComponent("services")
            url.appendPathComponent("aigc")
            url.appendPathComponent("multimodal-generation")
            url.appendPathComponent("generation")
            return url
        }

        url.appendPathComponent("api")
        url.appendPathComponent("v1")
        url.appendPathComponent("services")
        url.appendPathComponent("aigc")
        url.appendPathComponent("multimodal-generation")
        url.appendPathComponent("generation")
        return url
    }
}

private extension Data {
    mutating func appendUTF8Bytes(_ value: String) {
        append(Data(value.utf8))
    }

    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt32>.size))
    }
}

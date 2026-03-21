import Combine
import Foundation
import Security

private let defaultASRCredentialKeyRef = "asr.primary"
private let defaultTextCredentialKeyRef = "text.primary"

enum ProviderType: String, CaseIterable, Codable, Identifiable {
    case openAI
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI（官方）"
        case .openAICompatible:
            return "OpenAI 兼容"
        }
    }

    var shortLabel: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .openAICompatible:
            return "兼容"
        }
    }

    var defaultTranscriptionModelName: String {
        "whisper-1"
    }

    var defaultRewriteModelName: String {
        "gpt-4o-mini"
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
        }
    }
}

struct ASRConfig: Codable, Equatable {
    var providerType: ProviderType
    var baseURLString: String
    var modelName: String
    var keyRef: String

    init(
        providerType: ProviderType = .openAI,
        baseURLString: String? = nil,
        modelName: String? = nil,
        keyRef: String = defaultASRCredentialKeyRef
    ) {
        self.providerType = providerType
        self.baseURLString = baseURLString ?? providerType.fixedBaseURL?.absoluteString ?? ""
        self.modelName = modelName ?? providerType.defaultTranscriptionModelName
        self.keyRef = keyRef
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

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return "钥匙串操作失败，状态码：\(status)。"
        case .invalidCredentialEncoding:
            return "已存凭证无法解析。"
        }
    }
}

protocol ProviderCredentialStore {
    func loadAPIKey(for profileID: String) throws -> String?
    func saveAPIKey(_ value: String, for profileID: String) throws
    func deleteAPIKey(for profileID: String) throws
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
        case missing
        case saved
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

    @Published private(set) var asrCredentialState: CredentialState = .missing
    @Published private(set) var textCredentialState: CredentialState = .missing
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
        refreshCredentialState()
    }

    func refreshCredentialState() {
        do {
            let asr = try credentialStore.loadAPIKey(for: asrConfig.keyRef)
            asrCredentialState = (asr?.isEmpty == false) ? .saved : .missing
        } catch {
            asrCredentialState = .missing
            asrFeedbackMessage = "无法从钥匙串读取语音识别 API 密钥。"
        }

        do {
            let text = try credentialStore.loadAPIKey(for: textConfig.keyRef)
            textCredentialState = (text?.isEmpty == false) ? .saved : .missing
        } catch {
            textCredentialState = .missing
            textFeedbackMessage = "无法从钥匙串读取文本模型 API 密钥。"
        }
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
        asrConfig.providerType = type
        if !type.allowsCustomBaseURL {
            asrConfig.baseURLString = type.fixedBaseURL?.absoluteString ?? ""
        }
        if asrConfig.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            asrConfig.modelName = type.defaultTranscriptionModelName
        }
    }

    func updateTextProviderType(_ type: ProviderType) {
        textConfig.providerType = type
        if !type.allowsCustomBaseURL {
            textConfig.baseURLString = type.fixedBaseURL?.absoluteString ?? ""
        }
        if textConfig.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textConfig.modelName = type.defaultRewriteModelName
        }
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

    func updateTextModel(_ value: String) {
        textConfig.modelName = value
    }

    func testASRConnection() async -> ConnectionTestResult {
        let tester = ASRConnectionTester(credentialStore: credentialStore)
        let result = await tester.test(config: asrConfig)
        latestASRTestResult = result
        persistLatestASRTestResult()
        return result
    }

    func testTextConnection() async -> ConnectionTestResult {
        let tester = TextConnectionTester(credentialStore: credentialStore)
        let result = await tester.test(config: textConfig)
        latestTextTestResult = result
        persistLatestTextTestResult()
        return result
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
            baseURL: baseURL
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
            baseURL: asrConfig.providerType.fixedBaseURL ?? URL(string: "https://api.openai.com")!
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
            providerType: .openAI,
            baseURLString: "https://api.openai.com",
            modelName: ProviderType.openAI.defaultTranscriptionModelName,
            keyRef: defaultASRCredentialKeyRef
        )
    }

    private static func defaultTextConfig() -> TextConfig {
        TextConfig(
            providerType: .openAI,
            baseURLString: "https://api.openai.com",
            modelName: ProviderType.openAI.defaultRewriteModelName,
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

    static func parseProviderError(from data: Data) -> String {
        if
            let payload = try? JSONDecoder().decode(ConnectionTestErrorEnvelope.self, from: data),
            let message = payload.error.message?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        {
            return message
        }

        let fallback = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? "无错误详情" : fallback
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
}

private struct ConnectionTestTranscriptionPayload: Decodable {
    let text: String
}

private struct ConnectionTestErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let message: String?
    }

    let error: Payload
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

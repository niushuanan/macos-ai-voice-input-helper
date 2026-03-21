import Combine
import Foundation
import Security

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

struct ProviderProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var type: ProviderType
    var isEnabled: Bool
    var baseURLString: String
    var transcriptionModelName: String
    var rewriteModelName: String

    init(
        id: String = UUID().uuidString,
        name: String,
        type: ProviderType,
        isEnabled: Bool = true,
        baseURLString: String? = nil,
        transcriptionModelName: String? = nil,
        rewriteModelName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isEnabled = isEnabled
        self.baseURLString = baseURLString ?? ""
        self.transcriptionModelName = transcriptionModelName ?? type.defaultTranscriptionModelName
        self.rewriteModelName = rewriteModelName ?? type.defaultRewriteModelName
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

@MainActor
final class ProviderSettingsStore: ObservableObject {
    enum CredentialState: Equatable {
        case missing
        case saved
    }

    @Published private(set) var profiles: [ProviderProfile]

    @Published var selectedTranscriptionProfileID: String {
        didSet {
            defaults.set(selectedTranscriptionProfileID, forKey: defaultsTranscriptionProfileKey)
        }
    }

    @Published var selectedRewriteProfileID: String {
        didSet {
            defaults.set(selectedRewriteProfileID, forKey: defaultsRewriteProfileKey)
        }
    }

    @Published var selectedProfileIDForEditing: String {
        didSet {
            defaults.set(selectedProfileIDForEditing, forKey: defaultsEditingProfileKey)
            refreshCredentialState()
        }
    }

    @Published var apiKeyDraft: String = ""
    @Published private(set) var credentialState: CredentialState = .missing
    @Published private(set) var feedbackMessage: String?

    private let defaults: UserDefaults
    private let credentialStore: ProviderCredentialStore
    private let defaultsProfilesKey = "providers.profiles.v1"
    private let defaultsTranscriptionProfileKey = "providers.transcription.profile.id"
    private let defaultsRewriteProfileKey = "providers.rewrite.profile.id"
    private let defaultsEditingProfileKey = "providers.editing.profile.id"

    init(
        defaults: UserDefaults = .standard,
        credentialStore: ProviderCredentialStore
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore

        let loadedProfiles = ProviderSettingsStore.decodeProfiles(
            from: defaults.data(forKey: defaultsProfilesKey)
        )
        let migratedProfiles = ProviderSettingsStore.applyLegacyModelMigration(
            loadedProfiles: loadedProfiles,
            defaults: defaults
        )
        let initialProfiles = ProviderSettingsStore.sanitizeProfiles(migratedProfiles)
        self.profiles = initialProfiles

        let enabledIDs = Set(initialProfiles.filter(\.isEnabled).map(\.id))
        let fallbackID = initialProfiles.first?.id ?? ""

        let transcriptionID = defaults.string(forKey: defaultsTranscriptionProfileKey)
        let resolvedTranscriptionID = enabledIDs.contains(transcriptionID ?? "")
            ? transcriptionID!
            : (initialProfiles.first(where: \.isEnabled)?.id ?? fallbackID)

        let rewriteID = defaults.string(forKey: defaultsRewriteProfileKey)
        let resolvedRewriteID = enabledIDs.contains(rewriteID ?? "")
            ? rewriteID!
            : resolvedTranscriptionID

        let editingID = defaults.string(forKey: defaultsEditingProfileKey)
        let resolvedEditingID = initialProfiles.contains(where: { $0.id == editingID })
            ? (editingID ?? resolvedTranscriptionID)
            : resolvedTranscriptionID

        self.selectedTranscriptionProfileID = resolvedTranscriptionID
        self.selectedRewriteProfileID = resolvedRewriteID
        self.selectedProfileIDForEditing = resolvedEditingID

        persistProfiles()
        refreshCredentialState()
    }

    var enabledProfiles: [ProviderProfile] {
        profiles.filter(\.isEnabled)
    }

    var editingProfile: ProviderProfile? {
        profiles.first(where: { $0.id == selectedProfileIDForEditing })
    }

    var selectedTranscriptionProviderName: String {
        profile(with: selectedTranscriptionProfileID)?.name ?? "不可用服务商"
    }

    var selectedRewriteProviderName: String {
        profile(with: selectedRewriteProfileID)?.name ?? "不可用服务商"
    }

    var selectedProviderName: String {
        selectedTranscriptionProviderName
    }

    var modelName: String {
        profile(with: selectedTranscriptionProfileID)?.transcriptionModelName ?? ""
    }

    var rewriteModelName: String {
        profile(with: selectedRewriteProfileID)?.rewriteModelName ?? ""
    }

    var configurationValidationMessage: String? {
        validationMessageForTranscriptionProfile()
    }

    var rewriteConfigurationValidationMessage: String? {
        validationMessageForRewriteProfile()
    }

    var isConfigurationValid: Bool {
        configurationValidationMessage == nil
    }

    var isRewriteConfigurationValid: Bool {
        rewriteConfigurationValidationMessage == nil
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

    func refreshCredentialState() {
        do {
            let key = try credentialStore.loadAPIKey(for: selectedProfileIDForEditing)
            credentialState = (key?.isEmpty == false) ? .saved : .missing
        } catch {
            credentialState = .missing
            feedbackMessage = "无法从钥匙串读取 API 密钥。"
        }
    }

    @discardableResult
    func saveDraftedAPIKey() -> Bool {
        let normalized = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            feedbackMessage = "API 密钥不能为空。"
            return false
        }

        guard normalized.count >= 12 else {
            feedbackMessage = "API 密钥长度看起来太短。"
            return false
        }

        do {
            try credentialStore.saveAPIKey(normalized, for: selectedProfileIDForEditing)
            apiKeyDraft = ""
            credentialState = .saved
            feedbackMessage = "API 密钥已写入钥匙串。"
            return true
        } catch {
            feedbackMessage = "无法把 API 密钥写入钥匙串。"
            return false
        }
    }

    @discardableResult
    func clearSavedAPIKey() -> Bool {
        do {
            try credentialStore.deleteAPIKey(for: selectedProfileIDForEditing)
            credentialState = .missing
            feedbackMessage = "已删除已存 API 密钥。"
            return true
        } catch {
            feedbackMessage = "无法删除钥匙串中的 API 密钥。"
            return false
        }
    }

    func loadAPIKeyForTranscriptionProvider() throws -> String? {
        try credentialStore.loadAPIKey(for: selectedTranscriptionProfileID)
    }

    func loadAPIKeyForRewriteProvider() throws -> String? {
        try credentialStore.loadAPIKey(for: selectedRewriteProfileID)
    }

    func loadAPIKeyForActiveProvider() throws -> String? {
        try credentialStore.loadAPIKey(for: selectedProfileIDForEditing)
    }

    func addProfile() {
        let profile = ProviderProfile(
            name: "兼容配置 \(profiles.count + 1)",
            type: .openAICompatible,
            isEnabled: true
        )
        profiles.append(profile)
        selectedProfileIDForEditing = profile.id
        if enabledProfiles.count == 1 {
            selectedTranscriptionProfileID = profile.id
            selectedRewriteProfileID = profile.id
        }
        persistProfiles()
        ensureSelectionConsistency()
    }

    @discardableResult
    func deleteEditingProfile() -> Bool {
        guard profiles.count > 1 else {
            feedbackMessage = "至少要保留一个服务商配置。"
            return false
        }
        let deletingID = selectedProfileIDForEditing
        profiles.removeAll(where: { $0.id == deletingID })
        if let fallback = profiles.first {
            selectedProfileIDForEditing = fallback.id
        }
        try? credentialStore.deleteAPIKey(for: deletingID)
        persistProfiles()
        ensureSelectionConsistency()
        feedbackMessage = "已删除服务商配置。"
        return true
    }

    func updateEditingProfileName(_ value: String) {
        updateEditingProfile { profile in
            profile.name = value
        }
    }

    func updateEditingProfileType(_ type: ProviderType) {
        updateEditingProfile { profile in
            profile.type = type
            if !type.allowsCustomBaseURL {
                profile.baseURLString = type.fixedBaseURL?.absoluteString ?? ""
            }
            if profile.transcriptionModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.transcriptionModelName = type.defaultTranscriptionModelName
            }
            if profile.rewriteModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.rewriteModelName = type.defaultRewriteModelName
            }
        }
    }

    func updateEditingProfileEnabled(_ isEnabled: Bool) {
        updateEditingProfile { profile in
            profile.isEnabled = isEnabled
        }
        ensureSelectionConsistency()
    }

    func updateEditingBaseURL(_ value: String) {
        updateEditingProfile { profile in
            profile.baseURLString = value
        }
    }

    func updateEditingTranscriptionModel(_ value: String) {
        updateEditingProfile { profile in
            profile.transcriptionModelName = value
        }
    }

    func updateEditingRewriteModel(_ value: String) {
        updateEditingProfile { profile in
            profile.rewriteModelName = value
        }
    }

    private func updateEditingProfile(_ mutation: (inout ProviderProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileIDForEditing }) else {
            return
        }
        var edited = profiles[index]
        mutation(&edited)
        profiles[index] = edited
        persistProfiles()
        ensureSelectionConsistency()
    }

    private func ensureSelectionConsistency() {
        let enabled = enabledProfiles
        if enabled.isEmpty {
            if let first = profiles.first, let index = profiles.firstIndex(where: { $0.id == first.id }) {
                profiles[index].isEnabled = true
                persistProfiles()
            }
        }

        let enabledIDs = Set(enabledProfiles.map(\.id))
        if !enabledIDs.contains(selectedTranscriptionProfileID), let fallback = enabledProfiles.first {
            selectedTranscriptionProfileID = fallback.id
        }

        if !enabledIDs.contains(selectedRewriteProfileID), let fallback = enabledProfiles.first {
            selectedRewriteProfileID = fallback.id
        }

        if !profiles.contains(where: { $0.id == selectedProfileIDForEditing }), let fallback = profiles.first {
            selectedProfileIDForEditing = fallback.id
        }
    }

    private func profile(with id: String) -> ProviderProfile? {
        profiles.first(where: { $0.id == id })
    }

    private func fallbackTranscriptionConfiguration() -> SpeechProviderConfiguration {
        let profile = profile(with: selectedTranscriptionProfileID) ?? profiles.first!
        return SpeechProviderConfiguration(
            profileID: profile.id,
            providerType: profile.type,
            providerName: profile.name,
            modelName: profile.type.defaultTranscriptionModelName,
            baseURL: profile.type.fixedBaseURL ?? URL(string: "https://api.openai.com")!
        )
    }

    private func fallbackRewriteConfiguration() -> TextGenerationProviderConfiguration {
        let profile = profile(with: selectedRewriteProfileID) ?? profiles.first!
        return TextGenerationProviderConfiguration(
            profileID: profile.id,
            providerType: profile.type,
            providerName: profile.name,
            modelName: profile.type.defaultRewriteModelName,
            baseURL: profile.type.fixedBaseURL ?? URL(string: "https://api.openai.com")!
        )
    }

    private func resolvedTranscriptionConfiguration() -> SpeechProviderConfiguration? {
        guard let profile = profile(with: selectedTranscriptionProfileID) else {
            return nil
        }
        guard profile.isEnabled else {
            return nil
        }

        let normalizedModel = profile.transcriptionModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelValidationMessage(for: normalizedModel) == nil else {
            return nil
        }

        guard let baseURL = resolvedBaseURL(for: profile) else {
            return nil
        }

        return SpeechProviderConfiguration(
            profileID: profile.id,
            providerType: profile.type,
            providerName: profile.name,
            modelName: normalizedModel,
            baseURL: baseURL
        )
    }

    private func resolvedRewriteConfiguration() -> TextGenerationProviderConfiguration? {
        guard let profile = profile(with: selectedRewriteProfileID) else {
            return nil
        }
        guard profile.isEnabled else {
            return nil
        }

        let normalizedModel = profile.rewriteModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelValidationMessage(for: normalizedModel) == nil else {
            return nil
        }

        guard let baseURL = resolvedBaseURL(for: profile) else {
            return nil
        }

        return TextGenerationProviderConfiguration(
            profileID: profile.id,
            providerType: profile.type,
            providerName: profile.name,
            modelName: normalizedModel,
            baseURL: baseURL
        )
    }

    private func validationMessageForTranscriptionProfile() -> String? {
        guard let profile = profile(with: selectedTranscriptionProfileID) else {
            return "转写服务商配置不存在。"
        }
        return validationMessage(for: profile, lane: .transcription)
    }

    private func validationMessageForRewriteProfile() -> String? {
        guard let profile = profile(with: selectedRewriteProfileID) else {
            return "改写服务商配置不存在。"
        }
        return validationMessage(for: profile, lane: .rewrite)
    }

    private enum LaneKind {
        case transcription
        case rewrite
    }

    private func validationMessage(for profile: ProviderProfile, lane: LaneKind) -> String? {
        if !profile.isEnabled {
            return "当前服务商配置未启用。"
        }

        let modelName: String
        switch lane {
        case .transcription:
            modelName = profile.transcriptionModelName
        case .rewrite:
            modelName = profile.rewriteModelName
        }

        let normalizedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let modelIssue = modelValidationMessage(for: normalizedModel) {
            return modelIssue
        }

        if resolvedBaseURL(for: profile) == nil {
            return "接口地址（Base URL）无效。"
        }

        return nil
    }

    private func modelValidationMessage(for model: String) -> String? {
        if model.isEmpty {
            return "模型名不能为空。"
        }

        if model.count > 80 {
            return "模型名过长。"
        }

        if model.contains(where: \.isWhitespace) {
            return "模型名不能带空格。"
        }

        return nil
    }

    private func resolvedBaseURL(for profile: ProviderProfile) -> URL? {
        if let fixed = profile.type.fixedBaseURL {
            return fixed
        }

        let normalized = profile.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }

        guard
            let url = URL(string: normalized),
            let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http"
        else {
            return nil
        }

        return url
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: defaultsProfilesKey)
        }
    }

    private static func decodeProfiles(from data: Data?) -> [ProviderProfile] {
        guard
            let data,
            let decoded = try? JSONDecoder().decode([ProviderProfile].self, from: data)
        else {
            return seedProfiles()
        }
        return decoded
    }

    private static func sanitizeProfiles(_ loadedProfiles: [ProviderProfile]) -> [ProviderProfile] {
        var deduped: [ProviderProfile] = []
        var seen = Set<String>()

        for var profile in loadedProfiles {
            if seen.contains(profile.id) {
                continue
            }
            seen.insert(profile.id)

            if !profile.type.allowsCustomBaseURL {
                profile.baseURLString = profile.type.fixedBaseURL?.absoluteString ?? ""
            }

            if profile.transcriptionModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.transcriptionModelName = profile.type.defaultTranscriptionModelName
            }

            if profile.rewriteModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.rewriteModelName = profile.type.defaultRewriteModelName
            }

            if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.name = profile.type.displayName
            }

            deduped.append(profile)
        }

        if deduped.isEmpty {
            deduped = seedProfiles()
        }

        if !deduped.contains(where: \.isEnabled), !deduped.isEmpty {
            deduped[0].isEnabled = true
        }

        return deduped
    }

    private static func seedProfiles() -> [ProviderProfile] {
        [
            ProviderProfile(
                name: "OpenAI 官方",
                type: .openAI,
                isEnabled: true,
                baseURLString: "https://api.openai.com"
            ),
            ProviderProfile(
                name: "兼容接口",
                type: .openAICompatible,
                isEnabled: false,
                baseURLString: ""
            )
        ]
    }

    private static func applyLegacyModelMigration(
        loadedProfiles: [ProviderProfile],
        defaults: UserDefaults
    ) -> [ProviderProfile] {
        guard !loadedProfiles.isEmpty else {
            var seeded = seedProfiles()
            if
                let legacyModel = defaults.string(forKey: "speech.provider.model")?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !legacyModel.isEmpty
            {
                seeded[0].transcriptionModelName = legacyModel
            }
            if
                let legacyRewrite = defaults.string(forKey: "rewrite.provider.model")?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !legacyRewrite.isEmpty
            {
                seeded[0].rewriteModelName = legacyRewrite
            }
            return seeded
        }
        return loadedProfiles
    }
}

protocol SpeechProvider {
    var providerName: String { get }
}

struct PlaceholderSpeechProvider: SpeechProvider {
    let providerName: String = "用户自填云端服务商 Key"
}

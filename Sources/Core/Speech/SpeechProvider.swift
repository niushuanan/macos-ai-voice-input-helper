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
            return "OpenAI (Official)"
        case .openAICompatible:
            return "OpenAI-Compatible"
        }
    }

    var shortLabel: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .openAICompatible:
            return "Compatible"
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
            return "\(providerName) API key is missing."
        case let .audioFormatUnsupported(fileExtension):
            return "Audio format \(fileExtension) is not supported by this provider."
        case let .networkFailure(description):
            return "Network request failed: \(description)"
        case let .providerFailure(description):
            return "Provider returned an error: \(description)"
        case .invalidResponse:
            return "Provider response could not be parsed."
        case .cancelled:
            return "Transcription request was cancelled."
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
            return "Keychain operation failed with status \(status)."
        case .invalidCredentialEncoding:
            return "Stored credential could not be decoded."
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
        profile(with: selectedTranscriptionProfileID)?.name ?? "Unavailable Provider"
    }

    var selectedRewriteProviderName: String {
        profile(with: selectedRewriteProfileID)?.name ?? "Unavailable Provider"
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
            feedbackMessage = "Could not read API key from Keychain."
        }
    }

    @discardableResult
    func saveDraftedAPIKey() -> Bool {
        let normalized = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            feedbackMessage = "API key cannot be empty."
            return false
        }

        guard normalized.count >= 12 else {
            feedbackMessage = "API key looks too short."
            return false
        }

        do {
            try credentialStore.saveAPIKey(normalized, for: selectedProfileIDForEditing)
            apiKeyDraft = ""
            credentialState = .saved
            feedbackMessage = "API key saved in Keychain."
            return true
        } catch {
            feedbackMessage = "Could not save API key to Keychain."
            return false
        }
    }

    @discardableResult
    func clearSavedAPIKey() -> Bool {
        do {
            try credentialStore.deleteAPIKey(for: selectedProfileIDForEditing)
            credentialState = .missing
            feedbackMessage = "Saved API key was deleted."
            return true
        } catch {
            feedbackMessage = "Could not delete API key from Keychain."
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
            name: "Compatible Profile \(profiles.count + 1)",
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
            feedbackMessage = "At least one provider profile must remain."
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
        feedbackMessage = "Provider profile deleted."
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
            return "Transcription provider profile is missing."
        }
        return validationMessage(for: profile, lane: .transcription)
    }

    private func validationMessageForRewriteProfile() -> String? {
        guard let profile = profile(with: selectedRewriteProfileID) else {
            return "Rewrite provider profile is missing."
        }
        return validationMessage(for: profile, lane: .rewrite)
    }

    private enum LaneKind {
        case transcription
        case rewrite
    }

    private func validationMessage(for profile: ProviderProfile, lane: LaneKind) -> String? {
        if !profile.isEnabled {
            return "Selected provider profile is disabled."
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
            return "Base URL is invalid."
        }

        return nil
    }

    private func modelValidationMessage(for model: String) -> String? {
        if model.isEmpty {
            return "Model name cannot be empty."
        }

        if model.count > 80 {
            return "Model name is too long."
        }

        if model.contains(where: \.isWhitespace) {
            return "Model name should not include whitespace."
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
                name: "OpenAI Official",
                type: .openAI,
                isEnabled: true,
                baseURLString: "https://api.openai.com"
            ),
            ProviderProfile(
                name: "Compatible Endpoint",
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
    let providerName: String = "User-supplied cloud provider key"
}

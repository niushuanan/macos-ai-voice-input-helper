import Combine
import Foundation
import Security

enum SpeechProviderID: String, CaseIterable, Identifiable {
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        }
    }

    var defaultModelName: String {
        switch self {
        case .openAI:
            return "whisper-1"
        }
    }
}

struct SpeechProviderConfiguration: Equatable {
    let providerID: SpeechProviderID
    let modelName: String
}

struct SpeechTranscriptionRequest {
    let clip: RecordedAudioClip
    let lane: InputLane
    let contextSummary: String
}

struct SpeechTranscriptionResult: Equatable {
    let providerID: SpeechProviderID
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
    var id: SpeechProviderID { get }
    var displayName: String { get }
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
    func loadAPIKey(for providerID: SpeechProviderID) throws -> String?
    func saveAPIKey(_ value: String, for providerID: SpeechProviderID) throws
    func deleteAPIKey(for providerID: SpeechProviderID) throws
}

@MainActor
final class ProviderSettingsStore: ObservableObject {
    enum CredentialState: Equatable {
        case missing
        case saved
    }

    @Published var selectedProviderID: SpeechProviderID {
        didSet {
            defaults.set(selectedProviderID.rawValue, forKey: defaultsProviderKey)
            if modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                modelName = selectedProviderID.defaultModelName
            }
            refreshCredentialState()
        }
    }

    @Published var modelName: String {
        didSet {
            defaults.set(modelName, forKey: defaultsModelKey)
        }
    }

    @Published var apiKeyDraft: String = ""
    @Published private(set) var credentialState: CredentialState = .missing
    @Published private(set) var feedbackMessage: String?

    private let defaults: UserDefaults
    private let credentialStore: ProviderCredentialStore
    private let defaultsProviderKey = "speech.provider.id"
    private let defaultsModelKey = "speech.provider.model"

    init(
        defaults: UserDefaults = .standard,
        credentialStore: ProviderCredentialStore
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore

        let initialProviderID: SpeechProviderID
        if
            let rawProvider = defaults.string(forKey: defaultsProviderKey),
            let providerID = SpeechProviderID(rawValue: rawProvider)
        {
            initialProviderID = providerID
        } else {
            initialProviderID = .openAI
        }
        selectedProviderID = initialProviderID

        let storedModel = defaults.string(forKey: defaultsModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedModel, !storedModel.isEmpty {
            modelName = storedModel
        } else {
            modelName = initialProviderID.defaultModelName
        }

        refreshCredentialState()
    }

    var configuration: SpeechProviderConfiguration {
        SpeechProviderConfiguration(
            providerID: selectedProviderID,
            modelName: normalizedModelName
        )
    }

    var selectedProviderName: String {
        selectedProviderID.displayName
    }

    var isConfigurationValid: Bool {
        configurationValidationMessage == nil
    }

    var configurationValidationMessage: String? {
        if normalizedModelName.isEmpty {
            return "Model name cannot be empty."
        }

        if normalizedModelName.count > 80 {
            return "Model name is too long."
        }

        if normalizedModelName.contains(where: \.isWhitespace) {
            return "Model name should not include whitespace."
        }

        return nil
    }

    func refreshCredentialState() {
        do {
            let key = try credentialStore.loadAPIKey(for: selectedProviderID)
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
            try credentialStore.saveAPIKey(normalized, for: selectedProviderID)
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
            try credentialStore.deleteAPIKey(for: selectedProviderID)
            credentialState = .missing
            feedbackMessage = "Saved API key was deleted."
            return true
        } catch {
            feedbackMessage = "Could not delete API key from Keychain."
            return false
        }
    }

    func loadAPIKeyForActiveProvider() throws -> String? {
        try credentialStore.loadAPIKey(for: selectedProviderID)
    }

    private var normalizedModelName: String {
        modelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol SpeechProvider {
    var providerName: String { get }
}

struct PlaceholderSpeechProvider: SpeechProvider {
    let providerName: String = "User-supplied cloud provider key"
}

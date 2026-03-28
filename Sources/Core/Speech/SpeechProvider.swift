import Foundation
import Security

let defaultASRCredentialKeyRef = "asr.primary"
let defaultTextCredentialKeyRef = "text.primary"
let defaultCLITextCredentialKeyRef = "text.cli"
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
            return "本地 SenseVoice"
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
    let dictionaryTerms: [String]
    let dictionaryPromptHint: String?
    let dictionaryHotwordText: String?

    init(
        clip: RecordedAudioClip,
        lane: InputLane,
        contextSummary: String,
        dictionaryTerms: [String] = [],
        dictionaryPromptHint: String? = nil,
        dictionaryHotwordText: String? = nil
    ) {
        self.clip = clip
        self.lane = lane
        self.contextSummary = contextSummary
        self.dictionaryTerms = dictionaryTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedPrompt = dictionaryPromptHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.dictionaryPromptHint = (normalizedPrompt?.isEmpty == false) ? normalizedPrompt : nil
        let normalizedHotword = dictionaryHotwordText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.dictionaryHotwordText = (normalizedHotword?.isEmpty == false) ? normalizedHotword : nil
    }
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
            return "密钥存储操作失败，状态码：\(status)。"
        case .invalidCredentialEncoding:
            return "已存凭证无法解析。"
        case .interactionRequired:
            return "密钥访问需要用户交互。"
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

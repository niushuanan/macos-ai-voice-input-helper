import Foundation

struct V4ProviderSlotSnapshot: Equatable, Sendable {
    let slot: V4ModelSlot
    let providerType: ProviderType
    let providerDisplayName: String
    let modelName: String
    let baseURLString: String
    let credentialRef: V4ModelCredentialRef?
    let localModelPath: String?
    let sourceConfigurationKey: String
    let validationMessage: String?
}

struct V4ModelSlots: Codable, Equatable, Sendable {
    let asr: V4ModelEndpoint
    let text: V4ModelEndpoint
    let agent: V4ModelEndpoint

    func endpoint(for slot: V4ModelSlot) -> V4ModelEndpoint {
        switch slot {
        case .asr:
            return asr
        case .text:
            return text
        case .agent:
            return agent
        }
    }

    var all: [V4ModelEndpoint] {
        [asr, text, agent]
    }
}

enum V4ModelSlotErrorCode: String, Codable, Equatable, Sendable {
    case invalidConfiguration = "invalid_configuration"
    case unsupportedProvider = "unsupported_provider"
    case bridgeUnavailable = "bridge_unavailable"
    case credentialLoadFailed = "credential_load_failed"
}

struct V4ModelSlotResolutionError: Error, Codable, Equatable, Sendable, LocalizedError {
    let slot: V4ModelSlot
    let code: V4ModelSlotErrorCode
    let message: String
    let sourceConfigurationKey: String
    let providerIdentifier: String?

    var errorDescription: String? {
        message
    }
}


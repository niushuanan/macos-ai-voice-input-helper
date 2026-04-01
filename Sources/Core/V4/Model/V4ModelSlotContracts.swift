import Foundation

enum V4ModelSlot: String, Codable, Equatable, Sendable {
    case asr
    case text
    case agent
}

struct V4ModelCredentialRef: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    /// 指向 credential store 的稳定引用，不直接携带敏感值。
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct V4ModelEndpoint: Codable, Equatable, Sendable {
    /// 当前 endpoint 归属的模型槽位。
    let slot: V4ModelSlot
    /// Provider 的稳定标识，通常来自配置源。
    let providerIdentifier: String
    /// Provider 展示名，供日志与调试 UI 使用。
    let providerDisplayName: String
    /// 当前实际模型名。
    let modelName: String
    /// 当前 endpoint 的 base URL 文本，没有固定值时为空。
    let baseURLString: String
    /// 当前 endpoint 对应的 credential 引用，没有密钥时为空。
    let credentialRef: V4ModelCredentialRef?
    /// 本地模型路径，只有本地模型时才有值。
    let localModelPath: String?
    /// 当前 endpoint 对应的源配置键，供桥接层对位旧 store。
    let sourceConfigurationKey: String
}

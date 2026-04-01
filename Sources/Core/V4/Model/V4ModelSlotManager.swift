import Foundation

final class V4ModelSlotManager: @unchecked Sendable {
    private let bridge: V4ProviderSettingsBridge?

    init(bridge: V4ProviderSettingsBridge? = nil) {
        self.bridge = bridge
    }

    func resolve(_ slot: V4ModelSlot) async throws -> V4ModelEndpoint {
        guard let bridge else {
            return defaultEndpoint(for: slot)
        }

        let snapshot = await bridge.snapshot(for: slot)

        if slot == .asr, !snapshot.providerType.supportsTranscription {
            throw V4ModelSlotResolutionError(
                slot: slot,
                code: .unsupportedProvider,
                message: "\(slot.rawValue) 槽位当前 provider 不支持 ASR。",
                sourceConfigurationKey: snapshot.sourceConfigurationKey,
                providerIdentifier: snapshot.providerType.rawValue
            )
        }

        if slot != .asr, !snapshot.providerType.supportsRewrite {
            throw V4ModelSlotResolutionError(
                slot: slot,
                code: .unsupportedProvider,
                message: "\(slot.rawValue) 槽位当前 provider 不支持文本生成。",
                sourceConfigurationKey: snapshot.sourceConfigurationKey,
                providerIdentifier: snapshot.providerType.rawValue
            )
        }

        if let validationMessage = snapshot.validationMessage {
            throw V4ModelSlotResolutionError(
                slot: slot,
                code: .invalidConfiguration,
                message: validationMessage,
                sourceConfigurationKey: snapshot.sourceConfigurationKey,
                providerIdentifier: snapshot.providerType.rawValue
            )
        }

        let baseURLString: String
        if let fixedURL = snapshot.providerType.fixedBaseURL {
            baseURLString = fixedURL.absoluteString
        } else if let resolvedURL = ProviderConfigurationValidator.resolvedBaseURL(
            providerType: snapshot.providerType,
            baseURLString: snapshot.baseURLString
        ) {
            baseURLString = resolvedURL.absoluteString
        } else {
            throw V4ModelSlotResolutionError(
                slot: slot,
                code: .invalidConfiguration,
                message: "接口地址（Base URL）无效。",
                sourceConfigurationKey: snapshot.sourceConfigurationKey,
                providerIdentifier: snapshot.providerType.rawValue
            )
        }

        return V4ModelEndpoint(
            slot: snapshot.slot,
            providerType: snapshot.providerType,
            providerIdentifier: snapshot.providerType.rawValue,
            providerDisplayName: snapshot.providerDisplayName,
            modelName: snapshot.modelName,
            baseURLString: baseURLString,
            credentialRef: snapshot.credentialRef,
            localModelPath: snapshot.localModelPath,
            sourceConfigurationKey: snapshot.sourceConfigurationKey
        )
    }

    func resolveAll() async throws -> V4ModelSlots {
        async let asr = resolve(.asr)
        async let text = resolve(.text)
        async let agent = resolve(.agent)
        return try await V4ModelSlots(asr: asr, text: text, agent: agent)
    }

    func loadAPIKey(for slot: V4ModelSlot) async throws -> String? {
        guard let bridge else {
            return nil
        }

        do {
            return try await bridge.loadAPIKey(for: slot)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw V4ModelSlotResolutionError(
                slot: slot,
                code: .credentialLoadFailed,
                message: "读取 \(slot.rawValue) 槽位密钥失败。",
                sourceConfigurationKey: await sourceConfigurationKey(for: slot),
                providerIdentifier: nil
            )
        }
    }

    private func sourceConfigurationKey(for slot: V4ModelSlot) async -> String {
        guard let bridge else {
            return defaultSourceConfigurationKey(for: slot)
        }
        return await bridge.snapshot(for: slot).sourceConfigurationKey
    }

    private func defaultEndpoint(for slot: V4ModelSlot) -> V4ModelEndpoint {
        switch slot {
        case .asr:
            return V4ModelEndpoint(
                slot: .asr,
                providerType: .dashScopeQwenASR,
                providerIdentifier: ProviderType.dashScopeQwenASR.rawValue,
                providerDisplayName: ProviderType.dashScopeQwenASR.displayName,
                modelName: ProviderType.dashScopeQwenASR.defaultTranscriptionModelName,
                baseURLString: ProviderType.dashScopeQwenASR.fixedBaseURL?.absoluteString ?? "",
                credentialRef: V4ModelCredentialRef(rawValue: defaultASRCredentialKeyRef),
                localModelPath: nil,
                sourceConfigurationKey: defaultSourceConfigurationKey(for: .asr)
            )

        case .text:
            return V4ModelEndpoint(
                slot: .text,
                providerType: .openAICompatible,
                providerIdentifier: ProviderType.openAICompatible.rawValue,
                providerDisplayName: ProviderType.openAICompatible.displayName,
                modelName: ProviderType.openAICompatible.defaultRewriteModelName,
                baseURLString: "https://api.deepseek.com",
                credentialRef: V4ModelCredentialRef(rawValue: defaultTextCredentialKeyRef),
                localModelPath: nil,
                sourceConfigurationKey: defaultSourceConfigurationKey(for: .text)
            )

        case .agent:
            return V4ModelEndpoint(
                slot: .agent,
                providerType: .openAICompatible,
                providerIdentifier: ProviderType.openAICompatible.rawValue,
                providerDisplayName: ProviderType.openAICompatible.displayName,
                modelName: ProviderType.openAICompatible.defaultRewriteModelName,
                baseURLString: "https://api.deepseek.com",
                credentialRef: V4ModelCredentialRef(rawValue: defaultCLITextCredentialKeyRef),
                localModelPath: nil,
                sourceConfigurationKey: defaultSourceConfigurationKey(for: .agent)
            )
        }
    }

    private func defaultSourceConfigurationKey(for slot: V4ModelSlot) -> String {
        switch slot {
        case .asr:
            return "asrConfig"
        case .text:
            return "textConfig"
        case .agent:
            return "cliTextConfig"
        }
    }
}

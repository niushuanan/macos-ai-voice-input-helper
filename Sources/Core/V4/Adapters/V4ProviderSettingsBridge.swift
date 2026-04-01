import Foundation

@MainActor
final class V4ProviderSettingsBridge {
    private let providerSettingsStore: ProviderSettingsStore
    private let agentConfigResolver: @MainActor () -> TextConfig?
    private let agentAPIKeyLoader: @MainActor () throws -> String?

    init(
        providerSettingsStore: ProviderSettingsStore,
        agentConfigResolver: @escaping @MainActor () -> TextConfig? = { nil },
        agentAPIKeyLoader: (@MainActor () throws -> String?)? = nil
    ) {
        self.providerSettingsStore = providerSettingsStore
        self.agentConfigResolver = agentConfigResolver
        self.agentAPIKeyLoader = agentAPIKeyLoader ?? {
            try providerSettingsStore.loadAPIKeyForCLIProvider()
        }
    }

    func snapshot(for slot: V4ModelSlot) -> V4ProviderSlotSnapshot {
        switch slot {
        case .asr:
            return V4ProviderSlotSnapshot(
                slot: .asr,
                providerType: providerSettingsStore.asrConfig.providerType,
                providerDisplayName: providerSettingsStore.asrConfig.providerType.displayName,
                modelName: providerSettingsStore.asrConfig.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURLString: providerSettingsStore.asrConfig.baseURLString,
                credentialRef: V4ModelCredentialRef(rawValue: providerSettingsStore.asrConfig.keyRef),
                localModelPath: providerSettingsStore.asrConfig.localModelPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                sourceConfigurationKey: "asrConfig",
                validationMessage: providerSettingsStore.asrConfigurationValidationMessage
            )

        case .text:
            return snapshot(
                slot: .text,
                config: providerSettingsStore.textConfig,
                sourceConfigurationKey: "textConfig",
                validationMessage: providerSettingsStore.textConfigurationValidationMessage
            )

        case .agent:
            let agentConfig = agentConfigResolver() ?? providerSettingsStore.cliTextConfig
            let validationMessage = ProviderConfigurationValidator.validationMessage(
                providerType: agentConfig.providerType,
                baseURLString: agentConfig.baseURLString,
                modelName: agentConfig.modelName
            )
            let sourceConfigurationKey = agentConfig.keyRef == providerSettingsStore.cliTextConfig.keyRef
                ? "cliTextConfig"
                : "agentConfig"

            return snapshot(
                slot: .agent,
                config: agentConfig,
                sourceConfigurationKey: sourceConfigurationKey,
                validationMessage: validationMessage
            )
        }
    }

    func loadAPIKey(for slot: V4ModelSlot) throws -> String? {
        switch slot {
        case .asr:
            return try providerSettingsStore.loadAPIKeyForTranscriptionProvider()
        case .text:
            return try providerSettingsStore.loadAPIKeyForRewriteProvider()
        case .agent:
            return try agentAPIKeyLoader()
        }
    }

    private func snapshot(
        slot: V4ModelSlot,
        config: TextConfig,
        sourceConfigurationKey: String,
        validationMessage: String?
    ) -> V4ProviderSlotSnapshot {
        V4ProviderSlotSnapshot(
            slot: slot,
            providerType: config.providerType,
            providerDisplayName: config.providerType.displayName,
            modelName: config.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURLString: config.baseURLString,
            credentialRef: V4ModelCredentialRef(rawValue: config.keyRef),
            localModelPath: nil,
            sourceConfigurationKey: sourceConfigurationKey,
            validationMessage: validationMessage
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

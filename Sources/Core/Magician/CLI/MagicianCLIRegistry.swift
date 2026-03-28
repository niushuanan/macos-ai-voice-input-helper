import Foundation

final class MagicianCLIRegistry {
    private let feishuProvider: FeishuCLIProvider

    init(feishuProvider: FeishuCLIProvider = FeishuCLIProvider()) {
        self.feishuProvider = feishuProvider
    }

    func currentFeishuAvailability() -> FeishuCLIAvailability {
        FeishuCLIProvider.detectAvailability()
    }

    func groupedFeishuCatalog() -> [(group: String, operations: [FeishuCanonicalOperation])] {
        feishuProvider.groupedCatalog()
    }

    func executeFeishu(
        operation: FeishuCanonicalOperation,
        spokenCommand: String,
        explicitArguments: [String],
        availability: FeishuCLIAvailability
    ) async -> Result<MagicianExecutionResult, MagicianError> {
        await feishuProvider.execute(
            operation: operation,
            spokenCommand: spokenCommand,
            explicitArguments: explicitArguments,
            availability: availability
        )
    }
}

import Foundation

final class V4PermissionGate: V4ToolPermissionChecking, @unchecked Sendable {
    private let featureToggleStore: MagicianFeatureToggleStore?

    init(featureToggleStore: MagicianFeatureToggleStore? = nil) {
        self.featureToggleStore = featureToggleStore
    }

    func evaluate(
        spec: V4ToolSpec,
        request: V4RunRequest
    ) async -> V4PermissionDecision {
        guard spec.requiresPermission, let feature = spec.requiredFeature else {
            return V4PermissionDecision(
                behavior: .allow,
                traceID: request.traceID,
                lane: request.lane,
                toolName: spec.toolName,
                reason: "permission_not_required",
                userMessage: nil
            )
        }

        let enabled: Bool
        if let featureToggleStore {
            enabled = await MainActor.run {
                featureToggleStore.isEnabled(feature)
            }
        } else {
            enabled = request.enabledFeatureIDs.contains(feature.rawValue)
        }

        guard enabled else {
            return V4PermissionDecision(
                behavior: .deny,
                traceID: request.traceID,
                lane: request.lane,
                toolName: spec.toolName,
                reason: "feature_disabled:\(feature.rawValue)",
                userMessage: "当前未开启“\(feature.displayName)”能力，请先到设置里打开再试。"
            )
        }

        return V4PermissionDecision(
            behavior: .allow,
            traceID: request.traceID,
            lane: request.lane,
            toolName: spec.toolName,
            reason: "feature_enabled:\(feature.rawValue)",
            userMessage: nil
        )
    }
}

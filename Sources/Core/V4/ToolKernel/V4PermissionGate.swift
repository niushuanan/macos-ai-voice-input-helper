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
        guard spec.requiresPermission, let scope = spec.permissionScope else {
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
                featureToggleStore.isEnabled(scope)
            }
        } else {
            enabled = !request.enabledFeatureIDs.isDisjoint(with: scope.mappedFeatures.map(\.rawValue))
        }

        guard enabled else {
            return V4PermissionDecision(
                behavior: .deny,
                traceID: request.traceID,
                lane: request.lane,
                toolName: spec.toolName,
                reason: "scope_disabled:\(scope.rawValue)",
                userMessage: "当前未开启“\(scope.displayName)”权限，请先到设置里打开再试。"
            )
        }

        return V4PermissionDecision(
            behavior: .allow,
            traceID: request.traceID,
            lane: request.lane,
            toolName: spec.toolName,
            reason: "scope_enabled:\(scope.rawValue)",
            userMessage: nil
        )
    }
}

import Foundation

@MainActor
final class MagicianFeatureToggleStore: ObservableObject {
    @Published private(set) var scopeToggles: [MagicianPermissionScope: Bool]

    private let defaults: UserDefaults
    private let storageKey: String
    private let legacyStorageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "magician.permission_scopes.v2",
        legacyStorageKey: String = "magician.features.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.legacyStorageKey = legacyStorageKey
        self.scopeToggles = Self.loadScopes(
            defaults: defaults,
            storageKey: storageKey,
            legacyStorageKey: legacyStorageKey
        )
        if defaults.data(forKey: storageKey) == nil {
            persist()
        }
    }

    func isEnabled(_ feature: MagicianFeatureID) -> Bool {
        isEnabled(Self.scope(for: feature))
    }

    func isEnabled(_ scope: MagicianPermissionScope) -> Bool {
        scopeToggles[scope] ?? false
    }

    var enabledFeatures: Set<MagicianFeatureID> {
        Set(MagicianFeatureID.allCases.filter { isEnabled($0) })
    }

    var enabledScopes: Set<MagicianPermissionScope> {
        Set(scopeToggles.compactMap { key, value in
            value ? key : nil
        })
    }

    func hasAnyEnabledFeature() -> Bool {
        scopeToggles.values.contains(true)
    }

    func setEnabled(_ enabled: Bool, for feature: MagicianFeatureID) {
        setEnabled(enabled, for: Self.scope(for: feature))
    }

    func setEnabled(_ enabled: Bool, for scope: MagicianPermissionScope) {
        guard isEnabled(scope) != enabled else {
            return
        }
        scopeToggles[scope] = enabled
        persist()
    }

    func resetAll() {
        scopeToggles = Self.makeDefaultScopeToggles(enabledByDefault: false)
        persist()
    }

    private func persist() {
        let payload = Dictionary(
            uniqueKeysWithValues: scopeToggles.map { ($0.key.rawValue, $0.value) }
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: storageKey)
        }
    }

    static func scope(for feature: MagicianFeatureID) -> MagicianPermissionScope {
        switch feature {
        case .textTransform:
            return .textProcessing
        case .feishuCLI:
            return .feishu
        case .createEvent, .createNote, .composeEmailDraft:
            return .appleNativeApps
        }
    }

    static func features(for scope: MagicianPermissionScope) -> Set<MagicianFeatureID> {
        scope.mappedFeatures
    }

    private static func loadScopes(
        defaults: UserDefaults,
        storageKey: String,
        legacyStorageKey: String
    ) -> [MagicianPermissionScope: Bool] {
        if let decoded = decodeScopeToggles(from: defaults.data(forKey: storageKey)) {
            return decoded
        }

        // v2 首次上线：统一默认全开，避免历史版本迁移后能力被误关导致不可用。
        if defaults.data(forKey: legacyStorageKey) != nil {
            return makeDefaultScopeToggles(enabledByDefault: true)
        }

        return makeDefaultScopeToggles(enabledByDefault: true)
    }

    private static func makeDefaultScopeToggles(
        enabledByDefault: Bool
    ) -> [MagicianPermissionScope: Bool] {
        var result = Dictionary(
            uniqueKeysWithValues: MagicianPermissionScope.allCases.map { ($0, enabledByDefault) }
        )
        if result.count != MagicianPermissionScope.allCases.count {
            result = Dictionary(
                uniqueKeysWithValues: MagicianPermissionScope.allCases.map { ($0, enabledByDefault) }
            )
        }
        return result
    }

    private static func decodeScopeToggles(
        from data: Data?
    ) -> [MagicianPermissionScope: Bool]? {
        guard
            let data,
            let decoded = try? JSONDecoder().decode([String: Bool].self, from: data)
        else {
            return nil
        }

        var result = makeDefaultScopeToggles(enabledByDefault: true)
        for scope in MagicianPermissionScope.allCases {
            guard let value = decoded[scope.rawValue] else {
                continue
            }
            result[scope] = value
        }
        return result
    }
}

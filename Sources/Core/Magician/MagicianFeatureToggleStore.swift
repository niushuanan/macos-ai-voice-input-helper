import Foundation

@MainActor
final class MagicianFeatureToggleStore: ObservableObject {
    @Published private(set) var featureToggles: [MagicianFeatureID: Bool]

    private let defaults: UserDefaults
    private let storageKey: String
    private let legacyStorageKey: String
    private let legacyFeatureStorageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "magician.features.v3",
        legacyStorageKey: String = "magician.permission_scopes.v2",
        legacyFeatureStorageKey: String = "magician.features.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.legacyStorageKey = legacyStorageKey
        self.legacyFeatureStorageKey = legacyFeatureStorageKey
        self.featureToggles = Self.loadFeatures(
            defaults: defaults,
            storageKey: storageKey,
            legacyScopeStorageKey: legacyStorageKey,
            legacyFeatureStorageKey: legacyFeatureStorageKey
        )
        if defaults.data(forKey: storageKey) == nil {
            persist()
        }
    }

    func isEnabled(_ feature: MagicianFeatureID) -> Bool {
        featureToggles[feature.canonicalFeature] ?? false
    }

    var enabledFeatures: Set<MagicianFeatureID> {
        Set(featureToggles.compactMap { key, value in
            value ? key : nil
        })
    }

    func hasAnyEnabledFeature() -> Bool {
        featureToggles.values.contains(true)
    }

    func setEnabled(_ enabled: Bool, for feature: MagicianFeatureID) {
        let canonicalFeature = feature.canonicalFeature
        guard isEnabled(canonicalFeature) != enabled else {
            return
        }
        featureToggles[canonicalFeature] = enabled
        persist()
    }

    func resetAll() {
        featureToggles = Self.makeDefaultFeatureToggles(enabledByDefault: false)
        persist()
    }

    private func persist() {
        let payload = Dictionary(
            uniqueKeysWithValues: featureToggles.map { ($0.key.rawValue, $0.value) }
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func loadFeatures(
        defaults: UserDefaults,
        storageKey: String,
        legacyScopeStorageKey: String,
        legacyFeatureStorageKey: String
    ) -> [MagicianFeatureID: Bool] {
        if let decoded = decodeFeatureToggles(from: defaults.data(forKey: storageKey)) {
            return decoded
        }

        if let migrated = decodeLegacyScopeToggles(from: defaults.data(forKey: legacyScopeStorageKey)) {
            return migrated
        }

        if let migrated = decodeLegacyFeatureToggles(from: defaults.data(forKey: legacyFeatureStorageKey)) {
            return migrated
        }

        return makeDefaultFeatureToggles(enabledByDefault: true)
    }

    private static func makeDefaultFeatureToggles(
        enabledByDefault: Bool
    ) -> [MagicianFeatureID: Bool] {
        Dictionary(
            uniqueKeysWithValues: MagicianFeatureID.allCases.map { ($0, enabledByDefault) }
        )
    }

    private static func decodeFeatureToggles(
        from data: Data?
    ) -> [MagicianFeatureID: Bool]? {
        guard
            let data,
            let decoded = try? JSONDecoder().decode([String: Bool].self, from: data)
        else {
            return nil
        }

        var result = makeDefaultFeatureToggles(enabledByDefault: true)
        for feature in MagicianFeatureID.allCases {
            guard let value = decoded[feature.rawValue] else {
                continue
            }
            result[feature] = value
        }
        return result
    }

    private static func decodeLegacyScopeToggles(
        from data: Data?
    ) -> [MagicianFeatureID: Bool]? {
        guard
            let data,
            let decoded = try? JSONDecoder().decode([String: Bool].self, from: data)
        else {
            return nil
        }

        var result = makeDefaultFeatureToggles(enabledByDefault: true)
        if let textProcessing = decoded["text_processing"] {
            result[.textTransform] = textProcessing
        }
        if let appleNativeApps = decoded["apple_native_apps"] {
            result[.calendar] = appleNativeApps
            result[.markdownDocument] = appleNativeApps
            result[.mail] = appleNativeApps
            result[.music] = appleNativeApps
        }

        // 旧版没有单独的时钟能力。迁移时默认保持开启，避免提醒路径被意外关掉。
        result[.clock] = true
        return result
    }

    private static func decodeLegacyFeatureToggles(
        from data: Data?
    ) -> [MagicianFeatureID: Bool]? {
        guard
            let data,
            let decoded = try? JSONDecoder().decode([String: Bool].self, from: data)
        else {
            return nil
        }

        var result = makeDefaultFeatureToggles(enabledByDefault: true)
        for (rawKey, value) in decoded {
            guard let feature = MagicianFeatureID.fromStoredRawValue(rawKey)?.canonicalFeature else {
                continue
            }
            result[feature] = value
        }

        if decoded["create_event"] != nil || decoded["create_note"] != nil || decoded["control_music"] != nil {
            result[.clock] = true
        }
        return result
    }
}

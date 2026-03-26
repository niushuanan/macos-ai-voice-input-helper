import Foundation

@MainActor
final class MagicianFeatureToggleStore: ObservableObject {
    @Published private(set) var toggles: [MagicianFeatureID: Bool]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "magician.features.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.toggles = Self.decodeToggles(
            from: defaults.data(forKey: storageKey)
        )
    }

    func isEnabled(_ feature: MagicianFeatureID) -> Bool {
        toggles[feature] ?? false
    }

    var enabledFeatures: Set<MagicianFeatureID> {
        Set(toggles.compactMap { key, value in
            value ? key : nil
        })
    }

    func hasAnyEnabledFeature() -> Bool {
        toggles.values.contains(true)
    }

    func setEnabled(_ enabled: Bool, for feature: MagicianFeatureID) {
        guard isEnabled(feature) != enabled else {
            return
        }
        toggles[feature] = enabled
        persist()
    }

    func resetAll() {
        toggles = Dictionary(
            uniqueKeysWithValues: MagicianFeatureID.allCases.map { ($0, false) }
        )
        persist()
    }

    private func persist() {
        let payload = Dictionary(
            uniqueKeysWithValues: toggles.map { ($0.key.rawValue, $0.value) }
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func decodeToggles(from data: Data?) -> [MagicianFeatureID: Bool] {
        var result = Dictionary(
            uniqueKeysWithValues: MagicianFeatureID.allCases.map { ($0, false) }
        )
        guard
            let data,
            let decoded = try? JSONDecoder().decode([String: Bool].self, from: data)
        else {
            return result
        }

        for (rawKey, value) in decoded {
            guard let feature = MagicianFeatureID(rawValue: rawKey) else {
                continue
            }
            result[feature] = value
        }
        return result
    }
}

import XCTest
@testable import PulseType

@MainActor
final class MagicianFeatureToggleStoreTests: XCTestCase {
    func testDefaultsAllFeaturesEnabled() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests",
            legacyStorageKey: "magician.permission_scopes.tests",
            legacyFeatureStorageKey: "magician.features.v1.tests"
        )

        XCTAssertEqual(store.enabledFeatures, Set(MagicianFeatureID.allCases))
        for feature in MagicianFeatureID.allCases {
            XCTAssertTrue(store.isEnabled(feature))
        }
    }

    func testFeatureTogglePersistsAcrossInstances() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let first = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests",
            legacyStorageKey: "magician.permission_scopes.tests",
            legacyFeatureStorageKey: "magician.features.v1.tests"
        )
        first.setEnabled(false, for: .markdownDocument)
        first.setEnabled(false, for: .clock)

        let second = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests",
            legacyStorageKey: "magician.permission_scopes.tests",
            legacyFeatureStorageKey: "magician.features.v1.tests"
        )
        XCTAssertTrue(second.isEnabled(.textTransform))
        XCTAssertFalse(second.isEnabled(.markdownDocument))
        XCTAssertFalse(second.isEnabled(.createNote))
        XCTAssertFalse(second.isEnabled(.clock))
        XCTAssertTrue(second.isEnabled(.calendar))
        XCTAssertTrue(second.isEnabled(.mail))
        XCTAssertTrue(second.isEnabled(.music))
    }

    func testResetAllDisablesEveryFeature() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let first = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests",
            legacyStorageKey: "magician.permission_scopes.tests",
            legacyFeatureStorageKey: "magician.features.v1.tests"
        )
        first.resetAll()

        let second = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests",
            legacyStorageKey: "magician.permission_scopes.tests",
            legacyFeatureStorageKey: "magician.features.v1.tests"
        )
        XCTAssertFalse(second.hasAnyEnabledFeature())
        for feature in MagicianFeatureID.allCases {
            XCTAssertFalse(second.isEnabled(feature))
        }
    }

    func testLegacyScopeMigrationExpandsAppleNativeAppsIntoFourFeatures() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let legacyPayload = [
            "text_processing": false,
            "apple_native_apps": false
        ]
        let legacyData = try JSONEncoder().encode(legacyPayload)
        defaults.set(legacyData, forKey: "magician.permission_scopes.tests")

        let store = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests",
            legacyStorageKey: "magician.permission_scopes.tests",
            legacyFeatureStorageKey: "magician.features.v1.tests"
        )

        XCTAssertFalse(store.isEnabled(.textTransform))
        XCTAssertFalse(store.isEnabled(.calendar))
        XCTAssertFalse(store.isEnabled(.markdownDocument))
        XCTAssertFalse(store.isEnabled(.mail))
        XCTAssertFalse(store.isEnabled(.music))
        XCTAssertTrue(store.isEnabled(.clock))
    }

    func testLegacyFeatureMigrationMapsAliasesToCanonicalFeatures() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let legacyPayload = [
            "create_note": false,
            "control_music": false
        ]
        let legacyData = try JSONEncoder().encode(legacyPayload)
        defaults.set(legacyData, forKey: "magician.features.v1.tests")

        let store = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests",
            legacyStorageKey: "magician.permission_scopes.tests",
            legacyFeatureStorageKey: "magician.features.v1.tests"
        )

        XCTAssertFalse(store.isEnabled(.markdownDocument))
        XCTAssertFalse(store.isEnabled(.createNote))
        XCTAssertFalse(store.isEnabled(.music))
        XCTAssertFalse(store.isEnabled(.controlMusic))
    }

    func testLegacyFeatureMigrationKeepsClockEnabledForOldNativeActions() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let legacyPayload = [
            "create_event": false
        ]
        let legacyData = try JSONEncoder().encode(legacyPayload)
        defaults.set(legacyData, forKey: "magician.features.v1.tests")

        let store = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests",
            legacyStorageKey: "magician.permission_scopes.tests",
            legacyFeatureStorageKey: "magician.features.v1.tests"
        )

        XCTAssertFalse(store.isEnabled(.calendar))
        XCTAssertTrue(store.isEnabled(.clock))
    }

    private var defaultsSuiteName: String {
        "MagicianFeatureToggleStoreTests.\(name)"
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Unable to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}

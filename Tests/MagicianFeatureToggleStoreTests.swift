import XCTest
@testable import PulseType

@MainActor
final class MagicianFeatureToggleStoreTests: XCTestCase {
    func testDefaultsAllScopesEnabled() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.permission_scopes.tests",
            legacyStorageKey: "magician.features.tests"
        )

        XCTAssertEqual(
            store.enabledScopes,
            Set(MagicianPermissionScope.allCases)
        )
        for scope in MagicianPermissionScope.allCases {
            XCTAssertTrue(store.isEnabled(scope))
        }
        XCTAssertEqual(
            store.enabledFeatures,
            Set(MagicianFeatureID.allCases)
        )
    }

    func testScopeTogglePersistsAcrossInstances() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let first = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.permission_scopes.tests",
            legacyStorageKey: "magician.features.tests"
        )
        first.setEnabled(false, for: .feishu)
        first.setEnabled(false, for: .appleNativeApps)

        let second = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.permission_scopes.tests",
            legacyStorageKey: "magician.features.tests"
        )
        XCTAssertTrue(second.isEnabled(.textProcessing))
        XCTAssertFalse(second.isEnabled(.feishu))
        XCTAssertFalse(second.isEnabled(.appleNativeApps))
        XCTAssertFalse(second.isEnabled(.feishuCLI))
        XCTAssertFalse(second.isEnabled(.createEvent))
        XCTAssertFalse(second.isEnabled(.createNote))
        XCTAssertFalse(second.isEnabled(.composeEmailDraft))
    }

    func testFeatureSetterUpdatesMappedScope() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.permission_scopes.tests",
            legacyStorageKey: "magician.features.tests"
        )
        store.setEnabled(false, for: .createNote)

        XCTAssertFalse(store.isEnabled(.appleNativeApps))
        XCTAssertFalse(store.isEnabled(.createEvent))
        XCTAssertFalse(store.isEnabled(.createNote))
        XCTAssertFalse(store.isEnabled(.composeEmailDraft))
        XCTAssertTrue(store.isEnabled(.textTransform))
        XCTAssertTrue(store.isEnabled(.feishuCLI))
    }

    func testResetAllWritesDisabledScopes() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let first = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.permission_scopes.tests",
            legacyStorageKey: "magician.features.tests"
        )
        first.resetAll()

        let second = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.permission_scopes.tests",
            legacyStorageKey: "magician.features.tests"
        )
        XCTAssertFalse(second.hasAnyEnabledFeature())
        for scope in MagicianPermissionScope.allCases {
            XCTAssertFalse(second.isEnabled(scope))
        }
    }

    func testMigrationFromLegacyV1DefaultsToAllScopesEnabled() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let legacyPayload = [
            "text_transform": false,
            "create_event": false,
            "feishu_cli": false
        ]
        let legacyData = try JSONEncoder().encode(legacyPayload)
        defaults.set(legacyData, forKey: "magician.features.tests")

        let store = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.permission_scopes.tests",
            legacyStorageKey: "magician.features.tests"
        )
        XCTAssertEqual(store.enabledScopes, Set(MagicianPermissionScope.allCases))
        XCTAssertTrue(store.isEnabled(.textTransform))
        XCTAssertTrue(store.isEnabled(.feishuCLI))
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

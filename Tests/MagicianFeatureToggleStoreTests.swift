import XCTest
@testable import PulseType

@MainActor
final class MagicianFeatureToggleStoreTests: XCTestCase {
    func testDefaultsAllDisabled() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests"
        )

        for feature in MagicianFeatureID.allCases {
            XCTAssertFalse(store.isEnabled(feature))
        }
    }

    func testTogglesPersistAcrossInstances() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let first = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests"
        )
        first.setEnabled(true, for: .textTransform)
        first.setEnabled(true, for: .createEvent)

        let second = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests"
        )
        XCTAssertTrue(second.isEnabled(.textTransform))
        XCTAssertTrue(second.isEnabled(.createEvent))
        XCTAssertFalse(second.isEnabled(.createNote))
    }

    func testResetAllWritesDisabledState() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let first = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests"
        )
        first.setEnabled(true, for: .composeEmailDraft)
        first.resetAll()

        let second = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests"
        )
        XCTAssertFalse(second.isEnabled(.composeEmailDraft))
        XCTAssertFalse(second.isEnabled(.createNote))
    }

    func testLegacyWebSearchKeyIsIgnoredDuringDecode() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let payload = [
            "web_search": true,
            "text_transform": true
        ]
        let data = try JSONEncoder().encode(payload)
        defaults.set(data, forKey: "magician.features.tests")

        let store = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.tests"
        )

        XCTAssertTrue(store.isEnabled(.textTransform))
        XCTAssertFalse(store.isEnabled(.createEvent))
        XCTAssertEqual(store.enabledFeatures, [.textTransform])
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

import XCTest
@testable import PulseType

@MainActor
final class PermissionsCenterTests: XCTestCase {
    private let didPromptKey = "permissions.didPromptAccessibility"
    private let fingerprintKey = "permissions.accessibilityPromptFingerprint"

    func testAccessibilityDeniedWhenPromptedAndFingerprintMatches() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set(true, forKey: didPromptKey)
        defaults.set("fp.current", forKey: fingerprintKey)

        let center = PermissionsCenter(
            defaults: defaults,
            isAccessibilityTrusted: { false },
            accessibilityPromptFingerprintProvider: { "fp.current" }
        )

        center.refreshStatuses()

        XCTAssertEqual(center.snapshot.accessibility, .denied)
    }

    func testAccessibilityBecomesNotRequestedAfterBinaryFingerprintChanges() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set(true, forKey: didPromptKey)
        defaults.set("fp.old", forKey: fingerprintKey)

        let center = PermissionsCenter(
            defaults: defaults,
            isAccessibilityTrusted: { false },
            accessibilityPromptFingerprintProvider: { "fp.new" }
        )

        center.refreshStatuses()

        XCTAssertEqual(center.snapshot.accessibility, .notRequested)
    }

    func testAccessibilityGrantedClearsStalePromptFlags() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set(true, forKey: didPromptKey)
        defaults.set("fp.old", forKey: fingerprintKey)

        let center = PermissionsCenter(
            defaults: defaults,
            isAccessibilityTrusted: { true },
            accessibilityPromptFingerprintProvider: { "fp.old" }
        )

        center.refreshStatuses()

        XCTAssertEqual(center.snapshot.accessibility, .granted)
        XCTAssertFalse(defaults.bool(forKey: didPromptKey))
        XCTAssertNil(defaults.string(forKey: fingerprintKey))
    }

    private var defaultsSuiteName: String {
        "PermissionsCenterTests.\(name)"
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Unable to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}

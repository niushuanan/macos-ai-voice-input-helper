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

    func testAccessibilityPollingRefreshesStateAfterRequest() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        var isTrusted = false
        let center = PermissionsCenter(
            defaults: defaults,
            isAccessibilityTrusted: { isTrusted },
            accessibilityPromptFingerprintProvider: { "fp.current" },
            accessibilityPromptRequester: {
                isTrusted = true
            },
            accessibilityPollingAttemptCount: 3,
            accessibilityPollingIntervalNanoseconds: 1,
            pollingSleep: { _ in },
            runtimeDiagnosticsProvider: {
                PermissionRuntimeDiagnostics(
                    bundleIdentifier: "com.test.bundle",
                    bundlePath: "/Applications/PulseType.app",
                    executablePath: "/Applications/PulseType.app/Contents/MacOS/PulseType",
                    signatureSummary: "本地签名（ad-hoc）",
                    checkedAt: Date(timeIntervalSince1970: 1)
                )
            }
        )

        center.requestAccess(for: .accessibility)

        await Task.yield()
        await Task.yield()

        XCTAssertEqual(center.snapshot.accessibility, .granted)
    }

    func testRuntimeDiagnosticsUpdatesOnRefresh() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        var counter = 0
        let center = PermissionsCenter(
            defaults: defaults,
            isAccessibilityTrusted: { false },
            accessibilityPromptFingerprintProvider: { "fp.current" },
            runtimeDiagnosticsProvider: {
                counter += 1
                return PermissionRuntimeDiagnostics(
                    bundleIdentifier: "com.test.bundle",
                    bundlePath: "/Applications/PulseType.app",
                    executablePath: "/Applications/PulseType.app/Contents/MacOS/PulseType",
                    signatureSummary: "本地签名（ad-hoc）",
                    checkedAt: Date(timeIntervalSince1970: Double(counter))
                )
            }
        )

        let first = center.runtimeDiagnostics.checkedAt
        center.refreshStatuses()
        let second = center.runtimeDiagnostics.checkedAt

        XCTAssertTrue(second > first)
        XCTAssertEqual(center.runtimeDiagnostics.bundleIdentifier, "com.test.bundle")
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

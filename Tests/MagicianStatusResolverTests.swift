import EventKit
import XCTest
@testable import PulseType

final class MagicianStatusResolverTests: XCTestCase {
    private let resolver = MagicianStatusResolver()

    func testTextTransformNeedsPermissionWhenAccessibilityDenied() {
        let resolution = resolver.resolve(
            feature: .textTransform,
            isEnabled: false,
            dependencies: dependencies(accessibility: .denied)
        )

        XCTAssertEqual(resolution.status, .needsPermission)
        XCTAssertEqual(resolution.prompt?.primaryButtonTitle, "打开系统设置")
    }

    func testTextTransformEnabledWhenToggleOnAndAccessibilityGranted() {
        let resolution = resolver.resolve(
            feature: .textTransform,
            isEnabled: true,
            dependencies: dependencies(accessibility: .granted)
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertNil(resolution.prompt)
    }

    func testWebSearchNotEnabledWhenToggleOff() {
        let resolution = resolver.resolve(
            feature: .webSearch,
            isEnabled: false,
            dependencies: dependencies()
        )

        XCTAssertEqual(resolution.status, .notEnabled)
        XCTAssertNil(resolution.prompt)
    }

    func testCreateEventNeedsPermissionWhenNotDetermined() {
        let resolution = resolver.resolve(
            feature: .createEvent,
            isEnabled: false,
            dependencies: dependencies(eventStatus: .notDetermined)
        )

        XCTAssertEqual(resolution.status, .needsPermission)
        XCTAssertEqual(resolution.prompt?.primaryButtonTitle, "请求权限")
    }

    func testCreateNoteNeedsPermissionWhenShortcutsMissing() {
        let resolution = resolver.resolve(
            feature: .createNote,
            isEnabled: true,
            dependencies: dependencies(shortcutsAvailable: false)
        )

        XCTAssertEqual(resolution.status, .needsPermission)
        XCTAssertEqual(resolution.prompt?.primaryButtonTitle, "打开 Shortcuts")
    }

    func testComposeEmailNeedsPermissionWhenMailUnavailable() {
        let resolution = resolver.resolve(
            feature: .composeEmailDraft,
            isEnabled: true,
            dependencies: dependencies(composeEmailAvailable: false)
        )

        XCTAssertEqual(resolution.status, .needsPermission)
        XCTAssertEqual(resolution.prompt?.primaryButtonTitle, "打开 Mail")
    }

    private func dependencies(
        accessibility: PermissionState = .granted,
        eventStatus: EKAuthorizationStatus = .authorized,
        shortcutsAvailable: Bool = true,
        composeEmailAvailable: Bool = true
    ) -> MagicianDependencySnapshot {
        MagicianDependencySnapshot(
            accessibilityState: accessibility,
            eventAuthorizationStatus: eventStatus,
            shortcutsCLIAvailable: shortcutsAvailable,
            composeEmailAvailable: composeEmailAvailable
        )
    }
}


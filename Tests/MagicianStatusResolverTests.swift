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

    func testCreateEventNotEnabledWhenToggleOff() {
        let resolution = resolver.resolve(
            feature: .createEvent,
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
            dependencies: dependencies(
                shortcutsAvailable: false,
                createNoteShortcutExists: false,
                notesAppAvailable: false
            )
        )

        XCTAssertEqual(resolution.status, .needsPermission)
        XCTAssertEqual(resolution.prompt?.primaryButtonTitle, "打开 Notes")
    }

    func testCreateNoteEnabledWhenNotesAppAvailableWithoutShortcut() {
        let resolution = resolver.resolve(
            feature: .createNote,
            isEnabled: true,
            dependencies: dependencies(
                shortcutsAvailable: false,
                createNoteShortcutExists: false,
                notesAppAvailable: true
            )
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertNil(resolution.reason)
        XCTAssertNil(resolution.prompt)
    }

    func testCreateNoteNeedsPermissionWhenShortcutNameMissingAndNotesUnavailable() {
        let resolution = resolver.resolve(
            feature: .createNote,
            isEnabled: true,
            dependencies: dependencies(
                shortcutsAvailable: true,
                createNoteShortcutName: "PulseType-写入备忘录",
                createNoteShortcutExists: false,
                notesAppAvailable: false
            )
        )

        XCTAssertEqual(resolution.status, .needsPermission)
        XCTAssertEqual(resolution.reason, "备忘录服务不可用，请先打开 Notes 或配置 Shortcut“PulseType-写入备忘录”。")
        XCTAssertEqual(resolution.prompt?.primaryButtonTitle, "打开 Notes")
    }

    func testComposeEmailNeedsPermissionWhenMailUnavailable() {
        let resolution = resolver.resolve(
            feature: .composeEmailDraft,
            isEnabled: true,
            dependencies: dependencies(
                composeEmailAvailable: false,
                mailtoAvailable: false,
                mailAppAvailable: false
            )
        )

        XCTAssertEqual(resolution.status, .needsPermission)
        XCTAssertEqual(resolution.prompt?.primaryButtonTitle, "打开 Mail")
    }

    func testComposeEmailReadyWhenOnlyMailtoAvailable() {
        let resolution = resolver.resolve(
            feature: .composeEmailDraft,
            isEnabled: true,
            dependencies: dependencies(
                composeEmailAvailable: false,
                mailtoAvailable: true,
                mailAppAvailable: false
            )
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertNil(resolution.prompt)
    }

    func testComposeEmailReadyWhenOnlyMailAppAvailable() {
        let resolution = resolver.resolve(
            feature: .composeEmailDraft,
            isEnabled: true,
            dependencies: dependencies(
                composeEmailAvailable: false,
                mailtoAvailable: false,
                mailAppAvailable: true
            )
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertNil(resolution.prompt)
    }

    private func dependencies(
        accessibility: PermissionState = .granted,
        eventStatus: EKAuthorizationStatus = .fullAccess,
        shortcutsAvailable: Bool = true,
        createNoteShortcutName: String = "PulseType-写入备忘录",
        createNoteShortcutExists: Bool = true,
        notesAppAvailable: Bool = true,
        composeEmailAvailable: Bool = true,
        mailtoAvailable: Bool = true,
        mailAppAvailable: Bool = true
    ) -> MagicianDependencySnapshot {
        MagicianDependencySnapshot(
            accessibilityState: accessibility,
            eventAuthorizationStatus: eventStatus,
            shortcutsCLIAvailable: shortcutsAvailable,
            createNoteShortcutName: createNoteShortcutName,
            createNoteShortcutExists: createNoteShortcutExists,
            notesAppAvailable: notesAppAvailable,
            composeEmailAvailable: composeEmailAvailable,
            mailtoAvailable: mailtoAvailable,
            mailAppAvailable: mailAppAvailable
        )
    }
}

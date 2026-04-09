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

        XCTAssertEqual(resolution.status, .notEnabled)
        XCTAssertEqual(resolution.availability, .blocked)
        XCTAssertEqual(resolution.gateKind, .systemPermission)
        XCTAssertEqual(resolution.prompt?.primaryButtonTitle, "打开系统设置")
    }

    func testTextTransformNeedsModelWhenTextModelUnavailable() {
        let resolution = resolver.resolve(
            feature: .textTransform,
            isEnabled: true,
            dependencies: dependencies(textModelReady: false)
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertEqual(resolution.availability, .blocked)
        XCTAssertEqual(resolution.gateKind, .modelDependency)
        XCTAssertEqual(resolution.prompt?.primaryAction, .openSettingsSection(sectionID: "model"))
    }

    func testCalendarNotEnabledWhenToggleOff() {
        let resolution = resolver.resolve(
            feature: .calendar,
            isEnabled: false,
            dependencies: dependencies()
        )

        XCTAssertEqual(resolution.status, .notEnabled)
        XCTAssertEqual(resolution.availability, .ready)
        XCTAssertEqual(resolution.gateKind, .ready)
        XCTAssertNil(resolution.prompt)
    }

    func testCalendarNeedsPermissionWhenNotDetermined() {
        let resolution = resolver.resolve(
            feature: .calendar,
            isEnabled: false,
            dependencies: dependencies(eventStatus: .notDetermined)
        )

        XCTAssertEqual(resolution.status, .notEnabled)
        XCTAssertEqual(resolution.availability, .blocked)
        XCTAssertEqual(resolution.gateKind, .systemPermission)
        XCTAssertEqual(resolution.prompt?.primaryButtonTitle, "请求权限")
    }

    func testMarkdownDocumentEnabledWithoutSystemPermission() {
        let resolution = resolver.resolve(
            feature: .markdownDocument,
            isEnabled: true,
            dependencies: dependencies(
                composeEmailAvailable: false,
                mailtoAvailable: false,
                mailAppAvailable: false,
                musicAppAvailable: false,
                clockAppAvailable: false,
                clockAlarmSurfaceAvailable: false,
                clockTimerSurfaceAvailable: false
            )
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertEqual(resolution.availability, .ready)
        XCTAssertEqual(resolution.gateKind, .ready)
        XCTAssertNil(resolution.reason)
        XCTAssertNil(resolution.prompt)
    }

    func testMarkdownDocumentNotEnabledWhenToggleOff() {
        let resolution = resolver.resolve(
            feature: .markdownDocument,
            isEnabled: false,
            dependencies: dependencies()
        )

        XCTAssertEqual(resolution.status, .notEnabled)
        XCTAssertEqual(resolution.availability, .ready)
        XCTAssertEqual(resolution.gateKind, .ready)
        XCTAssertNil(resolution.prompt)
    }

    func testMailNeedsPermissionWhenMailUnavailable() {
        let resolution = resolver.resolve(
            feature: .mail,
            isEnabled: true,
            dependencies: dependencies(
                composeEmailAvailable: false,
                mailtoAvailable: false,
                mailAppAvailable: false
            )
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertEqual(resolution.availability, .blocked)
        XCTAssertEqual(resolution.gateKind, .serviceDependency)
        XCTAssertEqual(resolution.reason, "当前无法使用邮件，请先打开 Mail 并完成账号配置。")
        XCTAssertEqual(resolution.prompt?.primaryButtonTitle, "打开 Mail")
    }

    func testMailReadyWhenOnlyMailtoAvailable() {
        let resolution = resolver.resolve(
            feature: .mail,
            isEnabled: true,
            dependencies: dependencies(
                composeEmailAvailable: false,
                mailtoAvailable: true,
                mailAppAvailable: false
            )
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertEqual(resolution.availability, .ready)
        XCTAssertEqual(resolution.gateKind, .ready)
        XCTAssertNil(resolution.prompt)
    }

    func testMusicNeedsPermissionWhenMusicUnavailable() {
        let resolution = resolver.resolve(
            feature: .music,
            isEnabled: true,
            dependencies: dependencies(musicAppAvailable: false)
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertEqual(resolution.availability, .blocked)
        XCTAssertEqual(resolution.gateKind, .serviceDependency)
        XCTAssertEqual(resolution.prompt?.title, "Music 不可用")
        XCTAssertEqual(resolution.prompt?.primaryAction, .openMusicApp)
    }

    func testMusicReadyWhenMusicAvailable() {
        let resolution = resolver.resolve(
            feature: .music,
            isEnabled: true,
            dependencies: dependencies(musicAppAvailable: true)
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertEqual(resolution.availability, .ready)
        XCTAssertEqual(resolution.gateKind, .ready)
        XCTAssertNil(resolution.prompt)
    }

    func testClockNeedsNotificationPermissionWhenNotDetermined() {
        let resolution = resolver.resolve(
            feature: .clock,
            isEnabled: true,
            dependencies: dependencies(notificationAuthorizationStatus: .notDetermined)
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertEqual(resolution.availability, .blocked)
        XCTAssertEqual(resolution.gateKind, .systemPermission)
        XCTAssertEqual(resolution.prompt?.primaryAction, .requestNotificationAccess)
    }

    func testClockNeedsHandoffWhenNotificationReadyButClockUnavailable() {
        let resolution = resolver.resolve(
            feature: .clock,
            isEnabled: true,
            dependencies: dependencies(
                notificationAuthorizationStatus: .authorized,
                clockAppAvailable: false,
                clockAlarmSurfaceAvailable: false,
                clockTimerSurfaceAvailable: false
            )
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertEqual(resolution.availability, .blocked)
        XCTAssertEqual(resolution.gateKind, .serviceDependency)
        XCTAssertEqual(resolution.prompt?.title, "Clock 不可用")
        XCTAssertEqual(resolution.prompt?.primaryAction, .openClockApp(surface: .worldClock))
    }

    func testClockReadyWhenNotificationAndClockPathAvailable() {
        let resolution = resolver.resolve(
            feature: .clock,
            isEnabled: true,
            dependencies: dependencies(
                notificationAuthorizationStatus: .authorized,
                clockAppAvailable: true
            )
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertEqual(resolution.availability, .ready)
        XCTAssertEqual(resolution.gateKind, .ready)
        XCTAssertNil(resolution.prompt)
    }

    func testCalendarBlockedStateKeepsToggleStatusWhenPreviouslyEnabled() {
        let resolution = resolver.resolve(
            feature: .calendar,
            isEnabled: true,
            dependencies: dependencies(eventStatus: .denied)
        )

        XCTAssertEqual(resolution.status, .enabled)
        XCTAssertEqual(resolution.availability, .blocked)
        XCTAssertEqual(resolution.gateKind, .systemPermission)
    }

    private func dependencies(
        accessibility: PermissionState = .granted,
        textModelReady: Bool = true,
        eventStatus: EKAuthorizationStatus = .fullAccess,
        composeEmailAvailable: Bool = true,
        mailtoAvailable: Bool = true,
        mailAppAvailable: Bool = true,
        musicAppAvailable: Bool = true,
        notificationAuthorizationStatus: V4NotificationAuthorizationStatus = .authorized,
        clockAppAvailable: Bool = true,
        clockAlarmSurfaceAvailable: Bool = false,
        clockTimerSurfaceAvailable: Bool = false
    ) -> MagicianDependencySnapshot {
        MagicianDependencySnapshot(
            accessibilityState: accessibility,
            textModelReady: textModelReady,
            eventAuthorizationStatus: eventStatus,
            composeEmailAvailable: composeEmailAvailable,
            mailtoAvailable: mailtoAvailable,
            mailAppAvailable: mailAppAvailable,
            musicAppAvailable: musicAppAvailable,
            notificationAuthorizationStatus: notificationAuthorizationStatus,
            clockAppAvailable: clockAppAvailable,
            clockAlarmSurfaceAvailable: clockAlarmSurfaceAvailable,
            clockTimerSurfaceAvailable: clockTimerSurfaceAvailable
        )
    }
}

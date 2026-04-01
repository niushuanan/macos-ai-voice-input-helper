import XCTest
@testable import PulseType

final class V4ReminderSchedulerTests: XCTestCase {
    func testScheduleAuthorizedNotification() async {
        let center = TestNotificationCenterClient(status: .authorized)
        let now = makeDate(year: 2026, month: 4, day: 2, hour: 10, minute: 0)
        let scheduler = V4ReminderScheduler(
            notificationCenter: center,
            now: { now }
        )
        let item = V4TimeItem(
            id: "tm-1",
            sessionID: nil,
            runID: nil,
            traceID: nil,
            lane: .selectionRewrite,
            createdAt: makeDate(year: 2026, month: 4, day: 2, hour: 10, minute: 0),
            rawCommand: "今晚 8 点提醒我交方案",
            normalizedText: "交方案",
            scheduledAt: makeDate(year: 2026, month: 4, day: 2, hour: 20, minute: 0),
            notificationID: nil,
            tags: ["action:remind", "交方案"],
            status: .captured
        )

        let result = await scheduler.schedule(for: item)

        XCTAssertEqual(result.status, .scheduled)
        XCTAssertEqual(result.notificationID, "time-machine.tm-1")
        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(center.addedRequests.first?.title, "交方案")
    }

    func testDeniedPermissionReturnsFailure() async {
        let center = TestNotificationCenterClient(status: .denied)
        let now = makeDate(year: 2026, month: 4, day: 2, hour: 10, minute: 0)
        let scheduler = V4ReminderScheduler(
            notificationCenter: center,
            now: { now }
        )
        let item = V4TimeItem(
            id: "tm-2",
            sessionID: nil,
            runID: nil,
            traceID: nil,
            lane: .selectionRewrite,
            createdAt: makeDate(year: 2026, month: 4, day: 2, hour: 10, minute: 0),
            rawCommand: "今晚 8 点提醒我交方案",
            normalizedText: "交方案",
            scheduledAt: makeDate(year: 2026, month: 4, day: 2, hour: 20, minute: 0),
            notificationID: nil,
            tags: ["action:remind", "交方案"],
            status: .captured
        )

        let result = await scheduler.schedule(for: item)

        XCTAssertEqual(result.status, .failed)
        XCTAssertNil(result.notificationID)
        XCTAssertTrue(result.userMessage.contains("系统通知权限没开"))
        XCTAssertTrue(center.addedRequests.isEmpty)
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        return calendar.date(from: components)!
    }
}

private final class TestNotificationCenterClient: V4NotificationCenterClient, @unchecked Sendable {
    var status: V4NotificationAuthorizationStatus
    var requestAuthorizationResult = true
    private(set) var addedRequests: [V4NotificationRequestPayload] = []

    init(status: V4NotificationAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() async -> V4NotificationAuthorizationStatus {
        status
    }

    func requestAuthorization() async throws -> Bool {
        requestAuthorizationResult
    }

    func add(_ request: V4NotificationRequestPayload) async throws {
        addedRequests.append(request)
    }
}

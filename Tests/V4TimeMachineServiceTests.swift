import XCTest
@testable import PulseType

final class V4TimeMachineServiceTests: XCTestCase {
    func testCreateItemWithoutSchedule() async throws {
        let service = makeService()

        let result = try await service.create(
            rawCommand: "记一下 产品定价方案",
            context: makeContext()
        )

        XCTAssertEqual(result.item.status, .captured)
        XCTAssertNil(result.item.scheduledAt)
        XCTAssertNil(result.scheduleResult)
        XCTAssertEqual(result.item.normalizedText, "产品定价方案")
    }

    func testCreateItemWithReminderSchedulesNotification() async throws {
        let service = makeService()

        let result = try await service.remind(
            rawCommand: "30 分钟后提醒我回电话",
            context: makeContext()
        )

        XCTAssertEqual(result.item.status, .scheduled)
        XCTAssertEqual(result.parseResult?.status, .parsed)
        XCTAssertEqual(result.scheduleResult?.status, .scheduled)
        XCTAssertNotNil(result.item.notificationID)
        XCTAssertEqual(result.item.normalizedText, "回电话")
    }

    func testProfileDigestAggregatesTopicsAndTimeSlots() async throws {
        let service = makeService()

        _ = try await service.remind(
            rawCommand: "明早 9 点提醒我写周报",
            context: makeContext()
        )
        _ = try await service.remind(
            rawCommand: "今晚 8 点提醒我写周报",
            context: makeContext()
        )
        _ = try await service.create(
            rawCommand: "记一下 产品定价",
            context: makeContext()
        )

        let digest = await service.currentDigest()

        XCTAssertEqual(digest.frequentTopics.first?.value, "写周报")
        XCTAssertEqual(digest.frequentTopics.first?.count, 2)
        XCTAssertTrue(digest.reminderTimeSlots.map(\.value).contains("上午"))
        XCTAssertTrue(digest.reminderTimeSlots.map(\.value).contains("晚上"))
        XCTAssertTrue(digest.actionTags.map(\.value).contains("本地提醒"))
    }

    private func makeService() -> V4TimeMachineService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let center = TestNotificationCenterClient(status: .authorized)
        let now = makeDate(year: 2026, month: 4, day: 2, hour: 10, minute: 0)
        let scheduler = V4ReminderScheduler(
            notificationCenter: center,
            now: { now }
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return V4TimeMachineService(
            store: V4TimeMachineStore(historyDirectory: directory),
            parser: V4TimeParser(calendar: calendar),
            scheduler: scheduler
        )
    }

    private func makeContext() -> V4TimeMachineRequestContext {
        V4TimeMachineRequestContext(request: V4RunRequest(
            sessionID: V4SessionID(rawValue: "session"),
            runID: V4RunID(rawValue: "run"),
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "时光机测试",
            inputText: "时光机测试输入",
            requestedAt: makeDate(year: 2026, month: 4, day: 2, hour: 10, minute: 0)
        ))
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

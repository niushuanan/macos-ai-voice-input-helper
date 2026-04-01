import Foundation
import UserNotifications

enum V4NotificationAuthorizationStatus: String, Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown
}

struct V4NotificationRequestPayload: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let scheduledAt: Date
}

protocol V4NotificationCenterClient: Sendable {
    func authorizationStatus() async -> V4NotificationAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ request: V4NotificationRequestPayload) async throws
}

final class V4UNUserNotificationCenterClient: V4NotificationCenterClient, @unchecked Sendable {
    private let center: UNUserNotificationCenter
    private var calendar: Calendar

    init(
        center: UNUserNotificationCenter = .current(),
        calendar: Calendar = .current
    ) {
        self.center = center
        self.calendar = calendar
    }

    func authorizationStatus() async -> V4NotificationAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: Self.map(status: settings.authorizationStatus))
            }
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func add(_ request: V4NotificationRequestPayload) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: request.scheduledAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let notificationRequest = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(notificationRequest) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func map(status: UNAuthorizationStatus) -> V4NotificationAuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }
}

final class V4ReminderScheduler: @unchecked Sendable {
    private let notificationCenter: any V4NotificationCenterClient
    private let now: @Sendable () -> Date

    init(
        notificationCenter: any V4NotificationCenterClient = V4UNUserNotificationCenterClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.notificationCenter = notificationCenter
        self.now = now
    }

    func schedule(for item: V4TimeItem) async -> V4ReminderScheduleResult {
        guard let scheduledAt = item.scheduledAt else {
            return V4ReminderScheduleResult(
                status: .failed,
                scheduledAt: nil,
                notificationID: nil,
                userMessage: "缺少提醒时间，没法创建本地提醒。",
                debugMessage: "scheduledAt missing"
            )
        }

        guard scheduledAt.timeIntervalSince(now()) > 1 else {
            return V4ReminderScheduleResult(
                status: .failed,
                scheduledAt: scheduledAt,
                notificationID: nil,
                userMessage: "提醒时间已经过去了，请换一个将来的时间。",
                debugMessage: "scheduledAt not in future"
            )
        }

        do {
            let status = await notificationCenter.authorizationStatus()
            switch status {
            case .authorized, .provisional, .ephemeral:
                break
            case .notDetermined:
                let granted = try await notificationCenter.requestAuthorization()
                guard granted else {
                    return V4ReminderScheduleResult(
                        status: .failed,
                        scheduledAt: scheduledAt,
                        notificationID: nil,
                        userMessage: "已记录，但系统通知权限还没打开，提醒没有建成。",
                        debugMessage: "notification permission denied after prompt"
                    )
                }
            case .denied, .unknown:
                return V4ReminderScheduleResult(
                    status: .failed,
                    scheduledAt: scheduledAt,
                    notificationID: nil,
                    userMessage: "已记录，但系统通知权限没开，提醒没有建成。",
                    debugMessage: "notification permission denied"
                )
            }

            let notificationID = item.notificationID ?? "time-machine.\(item.id)"
            try await notificationCenter.add(
                V4NotificationRequestPayload(
                    identifier: notificationID,
                    title: item.normalizedText.isEmpty ? "时光机提醒" : item.normalizedText,
                    body: item.rawCommand,
                    scheduledAt: scheduledAt
                )
            )

            return V4ReminderScheduleResult(
                status: .scheduled,
                scheduledAt: scheduledAt,
                notificationID: notificationID,
                userMessage: "本地提醒已创建。",
                debugMessage: nil
            )
        } catch {
            return V4ReminderScheduleResult(
                status: .failed,
                scheduledAt: scheduledAt,
                notificationID: nil,
                userMessage: "已记录，但本地提醒创建失败，请稍后再试。",
                debugMessage: String(describing: error)
            )
        }
    }
}

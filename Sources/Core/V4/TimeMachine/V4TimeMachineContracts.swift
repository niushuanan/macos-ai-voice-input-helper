import Foundation

enum V4TimeItemStatus: String, Codable, Equatable, Sendable {
    case captured
    case scheduled
    case scheduleFailed = "schedule_failed"
    case cancelled
}

enum V4TimeParseStatus: String, Codable, Equatable, Sendable {
    case parsed
    case failed
}

enum V4TimeParseKind: String, Codable, Equatable, Sendable {
    case relative
    case absolute
    case weekday
    case ambiguous
}

enum V4ReminderScheduleStatus: String, Codable, Equatable, Sendable {
    case scheduled
    case failed
}

struct V4TimeItem: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let sessionID: V4SessionID?
    let runID: V4RunID?
    let traceID: V4TraceID?
    let lane: V4Lane?
    let createdAt: Date
    let rawCommand: String
    let normalizedText: String
    let scheduledAt: Date?
    let notificationID: String?
    let tags: [String]
    let status: V4TimeItemStatus
}

struct V4TimeParseHint: Codable, Equatable, Sendable {
    let code: String
    let userMessage: String
    let debugMessage: String
    let supportedExamples: [String]
}

struct V4TimeParseResult: Codable, Equatable, Sendable {
    let status: V4TimeParseStatus
    let kind: V4TimeParseKind?
    let matchedExpression: String?
    let normalizedText: String
    let scheduledAt: Date?
    let resolutionSummary: String
    let hint: V4TimeParseHint?
}

struct V4ReminderScheduleResult: Codable, Equatable, Sendable {
    let status: V4ReminderScheduleStatus
    let scheduledAt: Date?
    let notificationID: String?
    let userMessage: String
    let debugMessage: String?
}

struct V4TimeMachineRequestContext: Codable, Equatable, Sendable {
    let sessionID: V4SessionID
    let runID: V4RunID
    let traceID: V4TraceID
    let lane: V4Lane
    let requestedAt: Date

    init(request: V4RunRequest) {
        self.sessionID = request.sessionID
        self.runID = request.runID
        self.traceID = request.traceID
        self.lane = request.lane
        self.requestedAt = request.requestedAt
    }
}

struct V4TimeMachineCreateResult: Equatable, Sendable {
    let item: V4TimeItem
    let parseResult: V4TimeParseResult?
    let scheduleResult: V4ReminderScheduleResult?
    let profileDigest: V4UserProfileDigest
}

import Foundation

struct V4RunID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    /// 单次 V4 run 的稳定标识，供日志、历史与时光机串联。
    let rawValue: String

    init(rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }
}

struct V4SessionID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    /// 同一会话内多次 run 共用的标识，供桥接层做聚合。
    let rawValue: String

    init(rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }
}

struct V4StepID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    /// 单个 step 的稳定标识，供 step record、tool use、tool result 对齐。
    let rawValue: String

    init(rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }
}

struct V4TraceID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    /// 跨日志链路的追踪标识，生命周期覆盖一次完整执行。
    let rawValue: String

    init(rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }
}

enum V4Lane: String, CaseIterable, Codable, Equatable, Sendable {
    case directDictation
    case selectionRewrite
    case brainstormDiscussion
}

enum V4RunStatus: String, Codable, Equatable, Sendable {
    case queued
    case planning
    case executing
    case waitingForTool = "waiting_for_tool"
    case waitingForUser = "waiting_for_user"
    case verifying
    case completed
    case failed
    case cancelled
}

enum V4FailureCode: String, Codable, Equatable, Sendable {
    case none
    case invalidRequest = "invalid_request"
    case permissionDenied = "permission_denied"
    case modelUnavailable = "model_unavailable"
    case toolValidationFailed = "tool_validation_failed"
    case toolExecutionFailed = "tool_execution_failed"
    case verificationFailed = "verification_failed"
    case bridgeNotReady = "bridge_not_ready"
    case historyWriteFailed = "history_write_failed"
    case userCancelled = "user_cancelled"
    case unknown
}

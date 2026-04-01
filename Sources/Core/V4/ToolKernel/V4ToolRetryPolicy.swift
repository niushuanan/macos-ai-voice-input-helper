import Foundation

struct V4ToolRetryPolicy: Codable, Equatable, Sendable {
    let maxRetryCount: Int
    let retryableCodes: [V4FailureCode]

    init(
        maxRetryCount: Int,
        retryableCodes: [V4FailureCode]
    ) {
        self.maxRetryCount = max(0, maxRetryCount)
        self.retryableCodes = retryableCodes
    }

    var supportsRetry: Bool {
        maxRetryCount > 0 && !retryableCodes.isEmpty
    }

    func allowsRetry(
        error: V4ToolError,
        attemptCount: Int
    ) -> Bool {
        guard supportsRetry, error.isRetryable else {
            return false
        }
        guard retryableCodes.contains(error.code) else {
            return false
        }
        return attemptCount <= maxRetryCount
    }

    static let none = V4ToolRetryPolicy(maxRetryCount: 0, retryableCodes: [])
    static let transientSingleRetry = V4ToolRetryPolicy(
        maxRetryCount: 1,
        retryableCodes: [.toolExecutionFailed, .bridgeNotReady]
    )
    static let transientDoubleRetry = V4ToolRetryPolicy(
        maxRetryCount: 2,
        retryableCodes: [.toolExecutionFailed, .bridgeNotReady]
    )
}

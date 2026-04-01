import XCTest
@testable import PulseType

final class V4AgentLoopEngineTests: XCTestCase {
    func testSingleStepFinish() async throws {
        let engine = V4AgentLoopEngine()
        let request = makeRequest(command: "润色这段文字")

        let outcome = try await engine.run(
            request: request,
            onEvent: nil as (@Sendable (V4RuntimeEvent) -> Void)?
        )

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.stepRecords.count, 1)
        XCTAssertEqual(outcome.stepRecords.first?.toolName, "text.transform")
        XCTAssertEqual(outcome.failureCode, nil)
    }

    func testMultiStepContinueThenFinish() async throws {
        let engine = V4AgentLoopEngine()
        let request = makeRequest(command: "先润色这段文字，然后写进备忘录")

        let outcome = try await engine.run(
            request: request,
            onEvent: nil as (@Sendable (V4RuntimeEvent) -> Void)?
        )

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.stepRecords.count, 2)
        XCTAssertEqual(outcome.stepRecords.map(\.toolName), ["text.transform", "apple.notes.create"])
        XCTAssertEqual(outcome.stepRecords.first?.status, .completed)
        XCTAssertEqual(outcome.stepRecords.last?.status, .completed)
    }

    func testRetryThenSuccess() async throws {
        let planner = TestPlanner(toolName: "text.transform", title: "文字处理")
        let executor = RetryThenSuccessExecutor()
        let engine = V4AgentLoopEngine(
            planner: planner,
            postStepDecider: V4PostStepDeciderDefault(),
            verifier: V4VerifierDefault(),
            stepExecutor: { step, request, accumulatedStepRecords, turnIndex in
                try await executor.execute(
                    step: step,
                    request: request,
                    accumulatedStepRecords: accumulatedStepRecords,
                    turnIndex: turnIndex
                )
            }
        )

        let outcome = try await engine.run(
            request: makeRequest(command: "润色"),
            onEvent: nil as (@Sendable (V4RuntimeEvent) -> Void)?
        )

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(executor.callCount, 2)
        XCTAssertEqual(outcome.stepRecords.count, 1)
        XCTAssertEqual(outcome.stepRecords.first?.attemptCount, 2)
    }

    func testRetryExhaustedThenFail() async throws {
        let planner = TestPlanner(toolName: "text.transform", title: "文字处理")
        let executor = AlwaysRetryableFailureExecutor()
        let engine = V4AgentLoopEngine(
            planner: planner,
            postStepDecider: V4PostStepDeciderDefault(),
            verifier: V4VerifierDefault(),
            stepExecutor: { step, request, accumulatedStepRecords, turnIndex in
                try await executor.execute(
                    step: step,
                    request: request,
                    accumulatedStepRecords: accumulatedStepRecords,
                    turnIndex: turnIndex
                )
            }
        )

        let outcome = try await engine.run(
            request: makeRequest(command: "润色"),
            onEvent: nil as (@Sendable (V4RuntimeEvent) -> Void)?
        )

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(executor.callCount, 3)
        XCTAssertEqual(outcome.stepRecords.count, 1)
        XCTAssertEqual(outcome.stepRecords.first?.attemptCount, 3)
        XCTAssertEqual(outcome.failureCode, .toolExecutionFailed)
    }

    func testMaxTurnsExceeded() async throws {
        let engine = V4AgentLoopEngine(maxTurns: 1)
        let request = makeRequest(command: "先润色这段文字，然后再翻成英文")

        let outcome = try await engine.run(
            request: request,
            onEvent: nil as (@Sendable (V4RuntimeEvent) -> Void)?
        )

        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.failureCode, .maxTurnsExceeded)
        XCTAssertEqual(outcome.stepRecords.count, 1)
    }

    func testEventSequenceContainsStepLifecycle() async throws {
        let engine = V4AgentLoopEngine()
        let request = makeRequest(command: "润色这段文字")
        let collector = EventNameCollector()

        _ = try await engine.run(
            request: request,
            onEvent: { event in
                collector.append(event.name)
            }
        )

        XCTAssertOrderedSubset(
            collector.snapshot(),
            expected: [
                .requestAccepted,
                .stateChanged,
                .planReady,
                .stepStarted,
                .stepFinished,
                .verificationFinished,
                .runCompleted
            ]
        )
    }

    private func makeRequest(command: String) -> V4RunRequest {
        V4RunRequest(
            lane: .selectionRewrite,
            goalSummary: command,
            inputText: command,
            selectionText: "原始选中文本"
        )
    }

    private func XCTAssertOrderedSubset(
        _ actual: [V4RuntimeEventName],
        expected: [V4RuntimeEventName],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var cursor = 0
        for name in actual {
            if cursor < expected.count, name == expected[cursor] {
                cursor += 1
            }
        }
        XCTAssertEqual(cursor, expected.count, "event sequence mismatch: \(actual)", file: file, line: line)
    }
}

private struct TestPlanner: V4Planner {
    let toolName: String
    let title: String

    func plan(for request: V4RunRequest) async throws -> V4Plan {
        guard request.stepRecords.isEmpty else {
            return V4Plan(
                steps: [],
                terminalDecision: V4LoopDecision(action: .finish, message: "已完成。")
            )
        }
        return V4Plan(
            steps: [
                V4StepRecord(
                    traceID: request.traceID,
                    lane: request.lane,
                    goalSummary: request.goalSummary,
                    title: title,
                    status: .queued,
                    toolName: toolName,
                    inputSummary: request.inputText
                )
            ]
        )
    }
}

private final class RetryThenSuccessExecutor: @unchecked Sendable {
    private(set) var callCount = 0

    func execute(
        step: V4StepRecord,
        request: V4RunRequest,
        accumulatedStepRecords _: [V4StepRecord],
        turnIndex _: Int
    ) async throws -> V4ToolResult {
        callCount += 1
        let error: V4ToolError?
        if callCount == 1 {
            error = V4ToolError(
                failureCode: .toolExecutionFailed,
                userMessage: "临时失败",
                debugMessage: "first attempt failed",
                isRetryable: true
            )
        } else {
            error = nil
        }
        return V4ToolResult(
            runID: request.runID,
            stepID: step.id,
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            toolName: step.toolName ?? "text.transform",
            outputText: error == nil ? "成功输出" : nil,
            outputJSON: nil,
            evidenceSummary: error == nil ? "retry success" : "",
            startedAt: Date(),
            finishedAt: Date(),
            error: error
        )
    }
}

private final class AlwaysRetryableFailureExecutor: @unchecked Sendable {
    private(set) var callCount = 0

    func execute(
        step: V4StepRecord,
        request: V4RunRequest,
        accumulatedStepRecords _: [V4StepRecord],
        turnIndex _: Int
    ) async throws -> V4ToolResult {
        callCount += 1
        return V4ToolResult(
            runID: request.runID,
            stepID: step.id,
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            toolName: step.toolName ?? "text.transform",
            outputText: nil,
            outputJSON: nil,
            evidenceSummary: "",
            startedAt: Date(),
            finishedAt: Date(),
            error: V4ToolError(
                failureCode: .toolExecutionFailed,
                userMessage: "一直失败",
                debugMessage: "retryable failure",
                isRetryable: true
            )
        )
    }
}

private final class EventNameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [V4RuntimeEventName]()

    func append(_ value: V4RuntimeEventName) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [V4RuntimeEventName] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return snapshot
    }
}

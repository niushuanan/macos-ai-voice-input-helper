import XCTest
@testable import PulseType

final class V4AgentLoopEngineTests: XCTestCase {
    func testSingleStepFinish() async throws {
        let engine = V4AgentLoopEngine(
            stepExecutor: { step, request, _, _ in
                StaticSuccessExecutor().execute(step: step, request: request)
            }
        )
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
        let engine = V4AgentLoopEngine(
            stepExecutor: { step, request, _, _ in
                StaticSuccessExecutor().execute(step: step, request: request)
            }
        )
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

    func testResearchThenNotesUsesTwoStepFlowWithoutModel() async throws {
        let engine = V4AgentLoopEngine(
            planner: V4PlannerRuleBased(),
            stepExecutor: { step, request, _, _ in
                StaticSuccessExecutor().execute(step: step, request: request)
            }
        )
        let request = makeRequest(command: "请调研一下最近语音输入趋势，写一篇短文放到备忘录")

        let outcome = try await engine.run(
            request: request,
            onEvent: nil as (@Sendable (V4RuntimeEvent) -> Void)?
        )

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.stepRecords.map(\.toolName), ["text.transform", "apple.notes.create"])
    }

    func testEconomicWriteIntoDocumentUsesTwoStepNotesFlowWithoutModel() async throws {
        let engine = V4AgentLoopEngine(
            planner: V4PlannerRuleBased(),
            stepExecutor: { step, request, _, _ in
                StaticSuccessExecutor().execute(step: step, request: request)
            }
        )
        let request = makeRequest(command: "二零一五年中国上半年经济情况，并写进文档。")

        let outcome = try await engine.run(
            request: request,
            onEvent: nil as (@Sendable (V4RuntimeEvent) -> Void)?
        )

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.stepRecords.map(\.toolName), ["text.transform", "apple.notes.create"])
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

    func testPlannerDrivenDeciderAllowsDynamicNextTurnPlanning() async throws {
        let planner = SequencedPlanner()
        let engine = V4AgentLoopEngine(
            planner: planner,
            postStepDecider: V4PostStepDeciderPlannerDriven(),
            verifier: V4VerifierDefault(),
            maxTurns: 6,
            stepExecutor: { step, request, _, _ in
                StaticSuccessExecutor().execute(step: step, request: request)
            }
        )

        let outcome = try await engine.run(
            request: makeRequest(command: "帮我整理一下然后发给产品组"),
            onEvent: nil as (@Sendable (V4RuntimeEvent) -> Void)?
        )

        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.stepRecords.map(\.toolName), ["text.transform", "apple.mail.compose"])
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
                code: .toolExecutionFailed,
                toolID: step.toolName ?? "text.transform",
                messageForUser: "临时失败",
                messageForDebug: "first attempt failed",
                recoverAction: "retry_command",
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
            status: error == nil ? .success : .failed,
            outputText: error == nil ? "成功输出" : nil,
            evidenceSummary: error == nil ? "retry success" : "",
            rawPayload: nil,
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
            status: .failed,
            outputText: nil,
            evidenceSummary: "",
            rawPayload: nil,
            startedAt: Date(),
            finishedAt: Date(),
            error: V4ToolError(
                code: .toolExecutionFailed,
                toolID: step.toolName ?? "text.transform",
                messageForUser: "一直失败",
                messageForDebug: "retryable failure",
                recoverAction: "retry_command",
                isRetryable: true
            )
        )
    }
}

private struct StaticSuccessExecutor {
    func execute(step: V4StepRecord, request: V4RunRequest) -> V4ToolResult {
        let outputText: String?
        switch step.toolName {
        case "apple.notes.create":
            outputText = "已写入备忘录"
        default:
            outputText = request.selectionText ?? request.inputText
        }

        let evidenceSummary: String
        switch step.toolName {
        case "apple.notes.create":
            evidenceSummary = "apple.notes.create action=create; note_id=note_test_1"
        default:
            evidenceSummary = "\(step.toolName ?? "text.transform") completed"
        }

        return V4ToolResult(
            runID: request.runID,
            stepID: step.id,
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            toolName: step.toolName ?? "text.transform",
            status: .success,
            outputText: outputText,
            evidenceSummary: evidenceSummary,
            rawPayload: nil,
            startedAt: Date(),
            finishedAt: Date(),
            error: nil
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

private final class SequencedPlanner: V4Planner, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func plan(for request: V4RunRequest) async throws -> V4Plan {
        lock.lock()
        callCount += 1
        let current = callCount
        lock.unlock()

        switch current {
        case 1:
            return V4Plan(
                steps: [
                    V4StepRecord(
                        traceID: request.traceID,
                        lane: request.lane,
                        goalSummary: request.goalSummary,
                        title: "文字处理",
                        status: .queued,
                        toolName: "text.transform",
                        inputSummary: "把当前内容整理成可直接发送的邮件正文"
                    )
                ]
            )
        case 2:
            return V4Plan(
                steps: [
                    V4StepRecord(
                        traceID: request.traceID,
                        lane: request.lane,
                        goalSummary: request.goalSummary,
                        title: "整理邮件",
                        status: .queued,
                        toolName: "apple.mail.compose",
                        inputSummary: "给产品组发邮件"
                    )
                ]
            )
        default:
            return V4Plan(
                steps: [],
                terminalDecision: V4LoopDecision(action: .finish, message: "已完成。")
            )
        }
    }
}

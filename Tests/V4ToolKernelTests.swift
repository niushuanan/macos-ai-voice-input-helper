import Foundation
import XCTest
@testable import PulseType

final class V4ToolKernelTests: XCTestCase {
    func testUnknownToolID() async {
        let registry = V4ToolRegistry(tools: [])
        let kernel = V4ToolKernel(
            registry: registry,
            permissionGate: TestPermissionGate(),
            hookPipeline: V4ToolHookPipeline()
        )

        let result = await kernel.execute(toolUse: makeToolUse(toolName: "unknown.tool"), context: makeContext(toolName: "unknown.tool"))

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error?.code, .invalidRequest)
        XCTAssertEqual(result.error?.toolID, "unknown.tool")
    }

    func testSchemaValidationFail() async {
        let tool = KernelTestTool(
            toolName: "schema.tool",
            schema: V4ToolInputSchema(
                fields: [V4ToolInputField(name: "text", kind: .string, summary: "文本")]
            ),
            isConcurrencySafe: true
        ) { _, _ in
            XCTFail("schema fail 时不该进 execute")
            return V4ToolExecutionOutput(outputText: nil, evidenceSummary: "")
        }
        let kernel = V4ToolKernel(
            registry: V4ToolRegistry(tools: [tool]),
            permissionGate: TestPermissionGate(),
            hookPipeline: V4ToolHookPipeline()
        )

        let result = await kernel.execute(
            toolUse: makeToolUse(toolName: "schema.tool", inputJSON: #"{"text":1}"#),
            context: makeContext(toolName: "schema.tool")
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error?.code, .toolValidationFailed)
        XCTAssertTrue(result.error?.messageForUser.contains("字段 `text`") == true)
    }

    func testPermissionDenied() async {
        let tool = KernelTestTool(
            toolName: "guarded.tool",
            schema: V4ToolInputSchema(
                fields: [V4ToolInputField(name: "text", kind: .string, summary: "文本")]
            ),
            requiresPermission: true,
            isConcurrencySafe: false
        ) { _, _ in
            XCTFail("deny 时不该进 execute")
            return V4ToolExecutionOutput(outputText: nil, evidenceSummary: "")
        }
        let kernel = V4ToolKernel(
            registry: V4ToolRegistry(tools: [tool]),
            permissionGate: TestPermissionGate(
                decision: V4PermissionDecision(
                    behavior: .deny,
                    traceID: V4TraceID(rawValue: "trace"),
                    lane: .selectionRewrite,
                    toolName: "guarded.tool",
                    reason: "scope_off",
                    userMessage: "权限没开"
                )
            ),
            hookPipeline: V4ToolHookPipeline()
        )

        let result = await kernel.execute(
            toolUse: makeToolUse(toolName: "guarded.tool"),
            context: makeContext(toolName: "guarded.tool")
        )

        XCTAssertEqual(result.status, V4ToolResultStatus.denied)
        XCTAssertEqual(result.error?.code, .permissionDenied)
        XCTAssertEqual(result.error?.messageForUser, "权限没开")
    }

    func testConcurrencySafeBatchRunsInParallel() async {
        let recorder = TimingRecorder()
        let slowA = KernelTestTool(
            toolName: "parallel.a",
            schema: V4ToolInputSchema(fields: []),
            isConcurrencySafe: true
        ) { _, _ in
            await recorder.markStart("parallel.a")
            try? await Task.sleep(nanoseconds: 300_000_000)
            return V4ToolExecutionOutput(outputText: "A", evidenceSummary: "A")
        }
        let slowB = KernelTestTool(
            toolName: "parallel.b",
            schema: V4ToolInputSchema(fields: []),
            isConcurrencySafe: true
        ) { _, _ in
            await recorder.markStart("parallel.b")
            try? await Task.sleep(nanoseconds: 300_000_000)
            return V4ToolExecutionOutput(outputText: "B", evidenceSummary: "B")
        }
        let registry = V4ToolRegistry(tools: [slowA, slowB])
        let kernel = V4ToolKernel(registry: registry, permissionGate: TestPermissionGate(), hookPipeline: V4ToolHookPipeline())
        let orchestrator = V4ToolBatchOrchestrator(kernel: kernel, registry: registry)
        let toolUses = [makeToolUse(toolName: "parallel.a", inputJSON: "{}"), makeToolUse(toolName: "parallel.b", inputJSON: "{}")]
        let contexts = [makeContext(toolName: "parallel.a"), makeContext(toolName: "parallel.b")]

        let startedAt = ContinuousClock.now
        let results = await orchestrator.execute(toolUses: toolUses, contexts: contexts)
        let elapsed = startedAt.duration(to: .now)

        XCTAssertEqual(results.map(\.status), [.success, .success])
        XCTAssertLessThan(elapsed.components.seconds, 1)
        let startGap = await recorder.startGap()
        XCTAssertLessThan(startGap, 0.15)
    }

    func testNonConcurrencySafeRunsSerial() async {
        let recorder = TimingRecorder()
        let serialA = KernelTestTool(
            toolName: "serial.a",
            schema: V4ToolInputSchema(fields: []),
            isConcurrencySafe: false
        ) { _, _ in
            await recorder.markStart("serial.a")
            try? await Task.sleep(nanoseconds: 220_000_000)
            return V4ToolExecutionOutput(outputText: "A", evidenceSummary: "A")
        }
        let serialB = KernelTestTool(
            toolName: "serial.b",
            schema: V4ToolInputSchema(fields: []),
            isConcurrencySafe: false
        ) { _, _ in
            await recorder.markStart("serial.b")
            try? await Task.sleep(nanoseconds: 220_000_000)
            return V4ToolExecutionOutput(outputText: "B", evidenceSummary: "B")
        }
        let registry = V4ToolRegistry(tools: [serialA, serialB])
        let kernel = V4ToolKernel(registry: registry, permissionGate: TestPermissionGate(), hookPipeline: V4ToolHookPipeline())
        let orchestrator = V4ToolBatchOrchestrator(kernel: kernel, registry: registry)

        _ = await orchestrator.execute(
            toolUses: [makeToolUse(toolName: "serial.a", inputJSON: "{}"), makeToolUse(toolName: "serial.b", inputJSON: "{}")],
            contexts: [makeContext(toolName: "serial.a"), makeContext(toolName: "serial.b")]
        )

        let startGap = await recorder.startGap()
        XCTAssertGreaterThanOrEqual(startGap, 0.20)
    }

    func testToolErrorNormalized() async {
        let tool = KernelTestTool(
            toolName: "error.tool",
            schema: V4ToolInputSchema(fields: []),
            isConcurrencySafe: true
        ) { _, _ in
            struct SampleFailure: Error {}
            throw SampleFailure()
        }
        let kernel = V4ToolKernel(
            registry: V4ToolRegistry(tools: [tool]),
            permissionGate: TestPermissionGate(),
            hookPipeline: V4ToolHookPipeline()
        )

        let result = await kernel.execute(
            toolUse: makeToolUse(toolName: "error.tool", inputJSON: "{}"),
            context: makeContext(toolName: "error.tool")
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error?.code, .toolExecutionFailed)
        XCTAssertEqual(result.error?.toolID, "error.tool")
        XCTAssertEqual(result.error?.recoverAction, "retry_command")
    }

    func testResultOrderStable() async {
        let first = KernelTestTool(
            toolName: "order.first",
            schema: V4ToolInputSchema(fields: []),
            isConcurrencySafe: true
        ) { _, _ in
            try? await Task.sleep(nanoseconds: 250_000_000)
            return V4ToolExecutionOutput(
                outputText: "first",
                evidenceSummary: "first",
                rawPayload: .object(["index": .number(1)])
            )
        }
        let second = KernelTestTool(
            toolName: "order.second",
            schema: V4ToolInputSchema(fields: []),
            isConcurrencySafe: true
        ) { _, _ in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return V4ToolExecutionOutput(
                outputText: "second",
                evidenceSummary: "second",
                rawPayload: .object(["index": .number(2)])
            )
        }
        let registry = V4ToolRegistry(tools: [first, second])
        let kernel = V4ToolKernel(registry: registry, permissionGate: TestPermissionGate(), hookPipeline: V4ToolHookPipeline())
        let orchestrator = V4ToolBatchOrchestrator(kernel: kernel, registry: registry)

        let results = await orchestrator.execute(
            toolUses: [makeToolUse(toolName: "order.first", inputJSON: "{}"), makeToolUse(toolName: "order.second", inputJSON: "{}")],
            contexts: [makeContext(toolName: "order.first"), makeContext(toolName: "order.second")]
        )

        XCTAssertEqual(results.map(\.outputText), ["first", "second"])
        XCTAssertTrue(results[0].rawPayload?.contains(#""index":1"#) == true)
        XCTAssertTrue(results[1].rawPayload?.contains(#""index":2"#) == true)
    }

    private func makeToolUse(
        toolName: String,
        inputJSON: String = #"{"text":"demo"}"#
    ) -> V4ToolUse {
        V4ToolUse(
            runID: V4RunID(rawValue: "run"),
            stepID: V4StepID(rawValue: UUID().uuidString),
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "goal",
            toolName: toolName,
            inputJSON: inputJSON,
            inputSummary: "summary",
            requestedAt: Date()
        )
    }

    private func makeContext(toolName: String) -> V4ToolExecutionContext {
        let step = V4StepRecord(
            id: V4StepID(rawValue: UUID().uuidString),
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "goal",
            title: toolName,
            status: .queued,
            toolName: toolName,
            inputSummary: "summary"
        )
        let toolUse = V4ToolUse(
            runID: V4RunID(rawValue: "run"),
            stepID: step.id,
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "goal",
            toolName: toolName,
            inputJSON: "{}",
            inputSummary: "summary",
            requestedAt: Date()
        )
        return V4ToolExecutionContext(
            toolUse: toolUse,
            request: V4RunRequest(
                sessionID: V4SessionID(rawValue: "session"),
                runID: V4RunID(rawValue: "run"),
                traceID: V4TraceID(rawValue: "trace"),
                lane: .selectionRewrite,
                goalSummary: "goal",
                inputText: "input"
            ),
            step: step,
            accumulatedStepRecords: [],
            turnIndex: 1
        )
    }
}

private final class KernelTestTool: V4Tool, @unchecked Sendable {
    let spec: V4ToolSpec
    private let executeHandler: @Sendable (V4ToolArguments, V4ToolExecutionContext) async throws -> V4ToolExecutionOutput

    init(
        toolName: String,
        schema: V4ToolInputSchema,
        requiresPermission: Bool = false,
        isConcurrencySafe: Bool,
        executeHandler: @escaping @Sendable (V4ToolArguments, V4ToolExecutionContext) async throws -> V4ToolExecutionOutput
    ) {
        self.spec = V4ToolSpec(
            toolName: toolName,
            displayName: toolName,
            summary: toolName,
            supportedLanes: V4Lane.allCases,
            inputSchemaVersion: "v1",
            inputSchema: schema,
            requiresPermission: requiresPermission,
            permissionScope: requiresPermission ? .textProcessing : nil,
            isConcurrencySafe: isConcurrencySafe,
            mutatesUserData: !isConcurrencySafe,
            supportsStreamingResults: false
        )
        self.executeHandler = executeHandler
    }

    func execute(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        try await executeHandler(arguments, context)
    }
}

private struct TestPermissionGate: V4ToolPermissionChecking {
    var decision: V4PermissionDecision?

    func evaluate(spec: V4ToolSpec, request: V4RunRequest) async -> V4PermissionDecision {
        decision ?? V4PermissionDecision(
            behavior: .allow,
            traceID: request.traceID,
            lane: request.lane,
            toolName: spec.toolName,
            reason: "test_allow",
            userMessage: nil
        )
    }
}

private actor TimingRecorder {
    private var starts: [String: ContinuousClock.Instant] = [:]

    func markStart(_ name: String) {
        starts[name] = .now
    }

    func startGap() -> Double {
        let ordered = starts.keys.sorted()
        guard
            ordered.count >= 2,
            let first = starts[ordered[0]],
            let second = starts[ordered[1]]
        else {
            return .infinity
        }
        let duration = first.duration(to: second)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}

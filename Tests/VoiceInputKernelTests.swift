import Foundation
import XCTest
@testable import PulseType

final class VoiceInputKernelTests: XCTestCase {
    func testNormalStopReturnsSemanticallyEditedSegmentsInOrder() async throws {
        let capture = FakeVoiceAudioCaptureSession(clip: fixtureClip())
        let asr = FakeRealtimeASRSession()
        let textProvider = KernelSemanticTextProvider()
        let kernel = makeKernel(capture: capture, asr: asr, textProvider: textProvider)

        _ = try await kernel.start(context: fixtureContext(withSemanticEditing: true))
        try await waitUntil { await asr.startCount == 1 }
        await capture.enqueue(chunk(sequence: 0))
        await asr.enqueue(.completed(itemID: "item-1", transcript: "第一句"))
        await asr.enqueue(.completed(itemID: "item-2", transcript: "第二句"))

        let result = try await kernel.stop()

        guard case let .realtimeFinal(text, rawTranscript, _) = result else {
            return XCTFail("Expected realtime final result")
        }
        XCTAssertEqual(rawTranscript, "第一句第二句")
        XCTAssertEqual(text, "第一句。第二句。")
    }

    func testRealtimeFailureReturnsFallbackClipExactlyOnce() async throws {
        let clip = fixtureClip()
        let capture = FakeVoiceAudioCaptureSession(clip: clip)
        let asr = FakeRealtimeASRSession(startError: URLError(.cannotConnectToHost))
        let kernel = makeKernel(capture: capture, asr: asr)

        _ = try await kernel.start(context: fixtureContext())
        try await waitUntil { await asr.startCount == 1 }
        let result = try await kernel.stop()

        guard case let .batchFallback(returnedClip, reason) = result else {
            return XCTFail("Expected batch fallback")
        }
        XCTAssertEqual(returnedClip, clip)
        XCTAssertFalse(reason.isEmpty)
        let stopCount = await capture.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testStopDrainsFinalAudioChunkBeforeFinishingProvider() async throws {
        let capture = FakeVoiceAudioCaptureSession(
            clip: fixtureClip(),
            chunkYieldedDuringStop: chunk(sequence: 1)
        )
        let asr = FakeRealtimeASRSession()
        let kernel = makeKernel(capture: capture, asr: asr)

        _ = try await kernel.start(context: fixtureContext())
        try await waitUntil { await asr.startCount == 1 }
        await capture.enqueue(chunk(sequence: 0))
        await asr.enqueue(.completed(itemID: "item-1", transcript: "完成"))

        _ = try await kernel.stop()

        let operations = await asr.operations
        XCTAssertEqual(operations, ["start", "audio:0", "audio:1", "finish"])
    }

    func testCancelIgnoresLateProviderEventsAndRejectsStop() async throws {
        let capture = FakeVoiceAudioCaptureSession(clip: fixtureClip())
        let asr = FakeRealtimeASRSession()
        let kernel = makeKernel(capture: capture, asr: asr)
        let updateStream = try await kernel.start(context: fixtureContext())
        var updates = updateStream.makeAsyncIterator()
        try await waitUntil { await asr.startCount == 1 }

        await kernel.cancel()
        await asr.enqueue(.completed(itemID: "late", transcript: "不应出现"))

        let update = await updates.next()
        XCTAssertNil(update)
        await XCTAssertThrowsErrorAsync {
            _ = try await kernel.stop()
        }
        let cancelCount = await capture.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testSecondStartWhileActiveIsRejected() async throws {
        let capture = FakeVoiceAudioCaptureSession(clip: fixtureClip())
        let asr = FakeRealtimeASRSession()
        let kernel = makeKernel(capture: capture, asr: asr)
        _ = try await kernel.start(context: fixtureContext())

        await XCTAssertThrowsErrorAsync {
            _ = try await kernel.start(context: self.fixtureContext())
        }

        await kernel.cancel()
    }

    func testStopHasFixedSemanticDeadlineEvenWithManySlowSegments() async throws {
        let capture = FakeVoiceAudioCaptureSession(clip: fixtureClip())
        let asr = FakeRealtimeASRSession()
        let slowProvider = SlowKernelSemanticTextProvider()
        let kernel = VoiceInputKernel(
            capture: capture,
            realtimeSessionFactory: { asr },
            semanticEditorFactory: {
                SemanticEditor(provider: slowProvider, editTimeout: 2)
            },
            semanticFinalizationBudget: 0.05
        )

        _ = try await kernel.start(context: fixtureContext(withSemanticEditing: true))
        try await waitUntil { await asr.startCount == 1 }
        for index in 0..<12 {
            await asr.enqueue(
                .completed(itemID: "item-\(index)", transcript: "第\(index)段")
            )
        }
        try await waitUntil { await slowProvider.callCount > 0 }

        let startedAt = Date()
        let result = try await kernel.stop()
        let elapsed = Date().timeIntervalSince(startedAt)

        guard case let .realtimeFinal(text, rawTranscript, _) = result else {
            return XCTFail("Expected realtime final result")
        }
        XCTAssertEqual(text, rawTranscript)
        XCTAssertLessThan(elapsed, 0.5)
    }

    private func makeKernel(
        capture: FakeVoiceAudioCaptureSession,
        asr: FakeRealtimeASRSession,
        textProvider: KernelSemanticTextProvider = KernelSemanticTextProvider()
    ) -> VoiceInputKernel {
        VoiceInputKernel(
            capture: capture,
            realtimeSessionFactory: { asr },
            semanticEditorFactory: {
                SemanticEditor(provider: textProvider, editTimeout: 1)
            },
            semanticFinalizationBudget: 0.5
        )
    }

    private func fixtureContext(withSemanticEditing: Bool = false) -> VoiceSessionContext {
        let semanticContext: SemanticEditorContext? = withSemanticEditing
            ? SemanticEditorContext(
                configuration: TextGenerationProviderConfiguration(
                    profileID: "text-primary",
                    providerType: .openAICompatible,
                    providerName: "Test",
                    modelName: "test-model",
                    baseURL: URL(string: "https://example.com/v1")!
                ),
                apiKey: "test-key",
                appName: "Codex",
                bundleID: "com.openai.codex",
                appPrompt: nil,
                userSystemPrompt: nil,
                dictionaryTerms: []
            )
            : nil
        return VoiceSessionContext(
            asrContextText: "PulseType",
            semanticContext: semanticContext
        )
    }

    private func fixtureClip() -> RecordedAudioClip {
        RecordedAudioClip(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            fileURL: URL(fileURLWithPath: "/tmp/pulsetype-kernel-test.wav"),
            duration: 1,
            sampleRate: 16_000,
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func chunk(sequence: Int) -> VoiceAudioChunk {
        VoiceAudioChunk(sequence: sequence, pcmData: Data([UInt8(sequence)]), duration: 0.1)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition was not met before timeout")
    }
}

private actor FakeVoiceAudioCaptureSession: VoiceAudioCaptureSession {
    private let clip: RecordedAudioClip
    private let chunkYieldedDuringStop: VoiceAudioChunk?
    private var continuation: AsyncThrowingStream<VoiceAudioChunk, Error>.Continuation?
    private(set) var stopCount = 0
    private(set) var cancelCount = 0

    init(clip: RecordedAudioClip, chunkYieldedDuringStop: VoiceAudioChunk? = nil) {
        self.clip = clip
        self.chunkYieldedDuringStop = chunkYieldedDuringStop
    }

    func startCapture() async throws -> AsyncThrowingStream<VoiceAudioChunk, Error> {
        var captured: AsyncThrowingStream<VoiceAudioChunk, Error>.Continuation?
        let stream = AsyncThrowingStream<VoiceAudioChunk, Error> { continuation in
            captured = continuation
        }
        continuation = captured
        return stream
    }

    func stopCapture() async throws -> RecordedAudioClip {
        stopCount += 1
        if let chunkYieldedDuringStop {
            continuation?.yield(chunkYieldedDuringStop)
        }
        continuation?.finish()
        return clip
    }

    func cancelCapture() async {
        cancelCount += 1
        continuation?.finish(throwing: VoiceKernelFailure.cancelled)
    }

    func enqueue(_ chunk: VoiceAudioChunk) {
        continuation?.yield(chunk)
    }
}

private actor FakeRealtimeASRSession: RealtimeASRSession {
    nonisolated let events: AsyncThrowingStream<StreamingTranscriptEvent, Error>
    private let continuation: AsyncThrowingStream<StreamingTranscriptEvent, Error>.Continuation
    private let startError: Error?
    private(set) var startCount = 0
    private(set) var operations: [String] = []

    init(startError: Error? = nil) {
        self.startError = startError
        var captured: AsyncThrowingStream<StreamingTranscriptEvent, Error>.Continuation?
        events = AsyncThrowingStream { continuation in
            captured = continuation
        }
        continuation = captured!
    }

    func start(context: VoiceSessionContext) async throws {
        startCount += 1
        operations.append("start")
        if let startError {
            throw startError
        }
    }

    func append(_ chunk: VoiceAudioChunk) async throws {
        operations.append("audio:\(chunk.sequence)")
    }

    func finish() async throws {
        operations.append("finish")
        continuation.yield(.sessionFinished)
        continuation.finish()
    }

    func cancel() async {
        continuation.finish()
    }

    func enqueue(_ event: StreamingTranscriptEvent) {
        continuation.yield(event)
    }
}

private actor KernelSemanticTextProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAICompatible]

    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> TextGenerationResult {
        let source = request.userPrompt
            .components(separatedBy: "<<<TEXT\n").last?
            .components(separatedBy: "\nTEXT>>>").first ?? ""
        return TextGenerationResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            outputText: source.hasSuffix("。") ? source : "\(source)。"
        )
    }
}

private actor SlowKernelSemanticTextProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAICompatible]
    private(set) var callCount = 0

    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> TextGenerationResult {
        callCount += 1
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return TextGenerationResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            outputText: "不应等待到这里"
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        return
    }
}

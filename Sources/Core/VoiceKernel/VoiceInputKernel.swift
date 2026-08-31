import Foundation

protocol VoiceInputKernelRunning: Sendable {
    func start(context: VoiceSessionContext) async throws -> AsyncStream<VoiceKernelUpdate>
    func stop() async throws -> VoiceKernelResult
    func cancel() async
}

typealias VoiceInputKernelFactory = @MainActor () -> (any VoiceInputKernelRunning)?

protocol VoiceAudioCaptureSession: Sendable {
    func startCapture() async throws -> AsyncThrowingStream<VoiceAudioChunk, Error>
    func stopCapture() async throws -> RecordedAudioClip
    func cancelCapture() async
}

final class MainActorVoiceAudioCaptureAdapter: VoiceAudioCaptureSession, @unchecked Sendable {
    private let capture: any StreamingAudioCapture

    @MainActor
    init(capture: any StreamingAudioCapture) {
        self.capture = capture
    }

    func startCapture() async throws -> AsyncThrowingStream<VoiceAudioChunk, Error> {
        try await capture.startStreamingCapture()
    }

    func stopCapture() async throws -> RecordedAudioClip {
        try await capture.stopStreamingCapture()
    }

    func cancelCapture() async {
        await capture.cancelStreamingCapture()
    }
}

actor VoiceInputKernel: VoiceInputKernelRunning {
    typealias RealtimeSessionFactory = @Sendable () -> any RealtimeASRSession
    typealias SemanticEditorFactory = @Sendable () -> SemanticEditor

    private enum Lifecycle: Equatable {
        case idle
        case starting(UUID)
        case active(UUID)
        case stopping(UUID)
    }

    private enum RealtimePhase {
        case connecting
        case flushing
        case ready
        case failed
    }

    private let capture: any VoiceAudioCaptureSession
    private let realtimeSessionFactory: RealtimeSessionFactory
    private let semanticEditorFactory: SemanticEditorFactory
    private let semanticFinalizationBudget: TimeInterval
    private let maximumBufferedChunks = 50

    private var lifecycle: Lifecycle = .idle
    private var currentSessionID: UUID?
    private var realtimePhase: RealtimePhase = .connecting
    private var realtimeFailureReason: String?
    private var queuedAudio: [VoiceAudioChunk] = []
    private var ledger = TranscriptLedger()

    private var realtimeSession: (any RealtimeASRSession)?
    private var semanticEditor: SemanticEditor?
    private var semanticContext: SemanticEditorContext?
    private var updateContinuation: AsyncStream<VoiceKernelUpdate>.Continuation?

    private var connectionTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var editTasksBySegment: [String: Task<SemanticEditResult, Never>] = [:]
    private var segmentOrder: [String] = []
    private var segmentSourceByID: [String: String] = [:]
    private var segmentRevisionByID: [String: Int] = [:]

    init(
        capture: any VoiceAudioCaptureSession,
        realtimeSessionFactory: @escaping RealtimeSessionFactory,
        semanticEditorFactory: @escaping SemanticEditorFactory = {
            SemanticEditor()
        },
        semanticFinalizationBudget: TimeInterval = 0.8
    ) {
        self.capture = capture
        self.realtimeSessionFactory = realtimeSessionFactory
        self.semanticEditorFactory = semanticEditorFactory
        self.semanticFinalizationBudget = max(0, semanticFinalizationBudget)
    }

    func start(context: VoiceSessionContext) async throws -> AsyncStream<VoiceKernelUpdate> {
        guard lifecycle == .idle else {
            throw VoiceKernelFailure.sessionBusy
        }

        let sessionID = UUID()
        lifecycle = .starting(sessionID)
        currentSessionID = sessionID

        let chunkStream: AsyncThrowingStream<VoiceAudioChunk, Error>
        do {
            chunkStream = try await capture.startCapture()
        } catch {
            lifecycle = .idle
            currentSessionID = nil
            throw error
        }

        guard lifecycle == .starting(sessionID), currentSessionID == sessionID else {
            await capture.cancelCapture()
            throw VoiceKernelFailure.cancelled
        }

        var capturedContinuation: AsyncStream<VoiceKernelUpdate>.Continuation?
        let updates = AsyncStream<VoiceKernelUpdate>(
            bufferingPolicy: .bufferingNewest(64)
        ) { continuation in
            capturedContinuation = continuation
        }

        resetSessionState()
        currentSessionID = sessionID
        lifecycle = .active(sessionID)
        realtimePhase = .connecting
        semanticContext = context.semanticContext
        updateContinuation = capturedContinuation

        let realtimeSession = realtimeSessionFactory()
        let semanticEditor = semanticEditorFactory()
        self.realtimeSession = realtimeSession
        self.semanticEditor = semanticEditor

        eventTask = Task { [weak self] in
            do {
                for try await event in realtimeSession.events {
                    await self?.handleRealtimeEvent(event, sessionID: sessionID)
                }
            } catch {
                await self?.activateFallback(error, sessionID: sessionID)
            }
        }

        audioTask = Task { [weak self] in
            do {
                for try await chunk in chunkStream {
                    await self?.handleAudioChunk(chunk, sessionID: sessionID)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.activateFallback(error, sessionID: sessionID)
            }
        }

        connectionTask = Task { [weak self] in
            do {
                try await realtimeSession.start(context: context)
                await self?.markRealtimeReady(sessionID: sessionID)
            } catch {
                await self?.activateFallback(error, sessionID: sessionID)
            }
        }

        return updates
    }

    func stop() async throws -> VoiceKernelResult {
        guard case let .active(sessionID) = lifecycle else {
            throw VoiceKernelFailure.cancelled
        }
        lifecycle = .stopping(sessionID)

        let clip: RecordedAudioClip
        do {
            clip = try await capture.stopCapture()
        } catch {
            await cancelSession(sessionID: sessionID, cancelCapture: false)
            throw error
        }

        await connectionTask?.value
        await audioTask?.value

        if let reason = realtimeFailureReason {
            return await finishWithFallback(clip: clip, reason: reason, sessionID: sessionID)
        }

        guard let realtimeSession else {
            return await finishWithFallback(
                clip: clip,
                reason: "实时语音会话未建立",
                sessionID: sessionID
            )
        }

        do {
            try await realtimeSession.finish()
            await eventTask?.value
        } catch {
            return await finishWithFallback(
                clip: clip,
                reason: sanitizedReason(error),
                sessionID: sessionID
            )
        }

        guard isCurrent(sessionID) else {
            throw VoiceKernelFailure.cancelled
        }

        let rawTranscript = ledger.snapshot.finalText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTranscript.isEmpty else {
            return await finishWithFallback(
                clip: clip,
                reason: "实时转写没有返回有效文本",
                sessionID: sessionID
            )
        }

        let finalText = await resolveSemanticText(rawTranscript: rawTranscript)
        let result = VoiceKernelResult.realtimeFinal(
            text: finalText,
            rawTranscript: rawTranscript,
            clip: clip
        )
        finishSession(sessionID: sessionID)
        return result
    }

    func cancel() async {
        guard let sessionID = currentSessionID else {
            return
        }
        await cancelSession(sessionID: sessionID, cancelCapture: true)
    }

    private func handleAudioChunk(_ chunk: VoiceAudioChunk, sessionID: UUID) async {
        guard isCurrentAndRunning(sessionID), realtimeFailureReason == nil else {
            return
        }

        switch realtimePhase {
        case .connecting, .flushing:
            guard queuedAudio.count < maximumBufferedChunks else {
                await activateFallback(VoiceKernelFailure.audioBackpressure, sessionID: sessionID)
                return
            }
            queuedAudio.append(chunk)

        case .ready:
            guard let realtimeSession else {
                await activateFallback(
                    VoiceKernelFailure.connection("实时语音会话未建立"),
                    sessionID: sessionID
                )
                return
            }
            do {
                try await realtimeSession.append(chunk)
            } catch {
                await activateFallback(error, sessionID: sessionID)
            }

        case .failed:
            return
        }
    }

    private func markRealtimeReady(sessionID: UUID) async {
        guard
            isCurrentAndRunning(sessionID),
            realtimeFailureReason == nil,
            let realtimeSession
        else {
            return
        }

        realtimePhase = .flushing
        while !queuedAudio.isEmpty, realtimeFailureReason == nil {
            let chunk = queuedAudio.removeFirst()
            do {
                try await realtimeSession.append(chunk)
            } catch {
                await activateFallback(error, sessionID: sessionID)
                return
            }
        }
        guard realtimeFailureReason == nil else {
            return
        }
        realtimePhase = .ready
    }

    private func handleRealtimeEvent(
        _ event: StreamingTranscriptEvent,
        sessionID: UUID
    ) async {
        guard isCurrentAndRunning(sessionID), realtimeFailureReason == nil else {
            return
        }

        ledger.apply(event)
        switch event {
        case .delta:
            updateContinuation?.yield(.preview(ledger.snapshot))

        case let .completed(itemID, transcript):
            let source = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else {
                return
            }
            if segmentSourceByID[itemID] == nil {
                segmentOrder.append(itemID)
            }
            let revision = (segmentRevisionByID[itemID] ?? 0) + 1
            segmentRevisionByID[itemID] = revision
            segmentSourceByID[itemID] = source
            updateContinuation?.yield(.segmentCompleted(itemID: itemID, text: source))
            updateContinuation?.yield(.preview(ledger.snapshot))

            if
                let semanticContext,
                let semanticEditor
            {
                editTasksBySegment[itemID]?.cancel()
                editTasksBySegment[itemID] = Task {
                    await semanticEditor.edit(
                        segmentID: itemID,
                        revision: revision,
                        source: source,
                        context: semanticContext
                    )
                }
                await Task.yield()
            }

        case .sessionReady, .speechStarted, .sessionFinished:
            return
        }
    }

    private func activateFallback(_ error: Error, sessionID: UUID) async {
        guard isCurrentAndRunning(sessionID), realtimeFailureReason == nil else {
            return
        }
        let reason = sanitizedReason(error)
        realtimeFailureReason = reason
        realtimePhase = .failed
        queuedAudio.removeAll(keepingCapacity: false)
        updateContinuation?.yield(.fallbackActivated(reason: reason))
        await realtimeSession?.cancel()
    }

    private func finishWithFallback(
        clip: RecordedAudioClip,
        reason: String,
        sessionID: UUID
    ) async -> VoiceKernelResult {
        await realtimeSession?.cancel()
        let result = VoiceKernelResult.batchFallback(clip: clip, reason: reason)
        finishSession(sessionID: sessionID)
        return result
    }

    private func resolveSemanticText(rawTranscript: String) async -> String {
        guard semanticContext != nil, let semanticEditor else {
            return rawTranscript
        }

        let editedResults = await semanticEditor.finalize(
            deadline: semanticFinalizationBudget
        )
        let editedByID = Dictionary(
            uniqueKeysWithValues: editedResults.map { ($0.segmentID, $0) }
        )
        let composed = segmentOrder.reduce(into: "") { result, itemID in
            guard let source = segmentSourceByID[itemID] else {
                return
            }
            let revision = segmentRevisionByID[itemID]
            let edit = editedByID[itemID]
            let text = edit?.revision == revision ? edit?.outputText ?? source : source
            result = TranscriptTextComposer.join(result, text)
        }
        let normalized = composed.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? rawTranscript : normalized
    }

    private func cancelSession(sessionID: UUID, cancelCapture: Bool) async {
        guard isCurrent(sessionID) else {
            return
        }
        connectionTask?.cancel()
        audioTask?.cancel()
        eventTask?.cancel()
        editTasksBySegment.values.forEach { $0.cancel() }
        if cancelCapture {
            await capture.cancelCapture()
        }
        await realtimeSession?.cancel()
        finishSession(sessionID: sessionID)
    }

    private func finishSession(sessionID: UUID) {
        guard isCurrent(sessionID) else {
            return
        }
        updateContinuation?.finish()
        connectionTask?.cancel()
        audioTask?.cancel()
        eventTask?.cancel()
        editTasksBySegment.values.forEach { $0.cancel() }
        lifecycle = .idle
        currentSessionID = nil
        resetSessionState()
    }

    private func resetSessionState() {
        realtimePhase = .connecting
        realtimeFailureReason = nil
        queuedAudio.removeAll(keepingCapacity: false)
        ledger = TranscriptLedger()
        realtimeSession = nil
        semanticEditor = nil
        semanticContext = nil
        updateContinuation = nil
        connectionTask = nil
        audioTask = nil
        eventTask = nil
        editTasksBySegment.removeAll(keepingCapacity: false)
        segmentOrder.removeAll(keepingCapacity: false)
        segmentSourceByID.removeAll(keepingCapacity: false)
        segmentRevisionByID.removeAll(keepingCapacity: false)
    }

    private func isCurrent(_ sessionID: UUID) -> Bool {
        currentSessionID == sessionID
    }

    private func isCurrentAndRunning(_ sessionID: UUID) -> Bool {
        guard currentSessionID == sessionID else {
            return false
        }
        switch lifecycle {
        case let .active(activeID), let .stopping(activeID):
            return activeID == sessionID
        case .idle, .starting:
            return false
        }
    }

    private func sanitizedReason(_ error: Error) -> String {
        let detail = ASRConnectionTester.redactSensitiveText(error.localizedDescription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "实时语音服务不可用" : detail
    }
}

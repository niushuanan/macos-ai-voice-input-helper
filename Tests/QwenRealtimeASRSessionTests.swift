import Foundation
import XCTest
@testable import PulseType

final class QwenRealtimeASRSessionTests: XCTestCase {
    func testJSONPayloadBecomesWebSocketTextFrame() throws {
        let payload = Data(#"{"type":"session.update"}"#.utf8)

        XCTAssertEqual(
            try WebSocketJSONFrameEncoder.text(from: payload),
            #"{"type":"session.update"}"#
        )
    }

    func testConnectionObserverWaitsForWebSocketOpenCallback() async throws {
        let observer = WebSocketConnectionObserver()
        let completion = ConnectionCompletionFlag()
        let waitTask = Task {
            try await observer.waitUntilOpen(timeout: 1)
            await completion.markCompleted()
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        let completedBeforeOpen = await completion.isCompleted
        XCTAssertFalse(completedBeforeOpen)

        observer.markOpened()
        try await waitTask.value
        let completedAfterOpen = await completion.isCompleted
        XCTAssertTrue(completedAfterOpen)
    }

    func testConnectionObserverFailsWhenHandshakeNeverOpens() async {
        let observer = WebSocketConnectionObserver()

        await XCTAssertThrowsErrorAsync {
            try await observer.waitUntilOpen(timeout: 0.02)
        }
    }

    func testStartBuildsAuthenticatedRequestAndSendsConfigurationFirst() async throws {
        let transport = RecordingWebSocketTransport()
        let session = makeSession(transport: transport)

        try await session.start(context: VoiceSessionContext(asrContextText: "PulseType"))

        let connectedRequest = await transport.connectedRequest
        let request = try XCTUnwrap(connectedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "realtime=v1")
        let sentEventTypes = await transport.sentEventTypes
        XCTAssertEqual(sentEventTypes, ["session.update"])

        await session.cancel()
    }

    func testFinishIsSentAfterTheLastAudioChunkAndWaitsForSessionFinished() async throws {
        let transport = RecordingWebSocketTransport()
        let session = makeSession(transport: transport)
        try await session.start(context: VoiceSessionContext(asrContextText: ""))
        try await session.append(
            VoiceAudioChunk(sequence: 0, pcmData: Data([1, 2, 3]), duration: 0.05)
        )

        let finishTask = Task {
            try await session.finish()
        }
        try await waitUntil {
            await transport.sentEventTypes.last == "session.finish"
        }

        let sentEventTypes = await transport.sentEventTypes
        XCTAssertEqual(sentEventTypes, [
            "session.update",
            "input_audio_buffer.append",
            "session.finish"
        ])
        XCTAssertFalse(finishTask.isCancelled)

        await transport.enqueue(Data(#"{"type":"session.finished"}"#.utf8))
        try await finishTask.value
    }

    func testIncomingDeltaIsExposedAsProviderNeutralEvent() async throws {
        let transport = RecordingWebSocketTransport()
        let session = makeSession(transport: transport)
        var iterator = session.events.makeAsyncIterator()
        try await session.start(context: VoiceSessionContext(asrContextText: ""))

        await transport.enqueue(
            Data(
                #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item-1","text":"你好","stash":"世界"}"#.utf8
            )
        )

        let event = try await iterator.next()
        XCTAssertEqual(
            event,
            .delta(itemID: "item-1", confirmedText: "你好", tentativeText: "世界")
        )

        await session.cancel()
    }

    func testCancelClosesTransportAndRejectsLateAudio() async throws {
        let transport = RecordingWebSocketTransport()
        let session = makeSession(transport: transport)
        try await session.start(context: VoiceSessionContext(asrContextText: ""))

        await session.cancel()

        let closeCount = await transport.closeCount
        XCTAssertEqual(closeCount, 1)
        await XCTAssertThrowsErrorAsync {
            try await session.append(
                VoiceAudioChunk(sequence: 1, pcmData: Data([9]), duration: 0.05)
            )
        }
    }

    func testServerErrorTerminatesEventStreamAndClosesTransport() async throws {
        let transport = RecordingWebSocketTransport()
        let session = makeSession(transport: transport)
        var iterator = session.events.makeAsyncIterator()
        try await session.start(context: VoiceSessionContext(asrContextText: ""))

        await transport.enqueue(
            Data(#"{"type":"error","error":{"code":"quota_exceeded","message":"额度不足"}}"#.utf8)
        )

        do {
            _ = try await iterator.next()
            XCTFail("Expected provider failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("quota_exceeded"))
        }
        try await waitUntil {
            await transport.closeCount == 1
        }
    }

    private func makeSession(
        transport: RecordingWebSocketTransport
    ) -> QwenRealtimeASRSession {
        QwenRealtimeASRSession(
            transport: transport,
            configuration: QwenRealtimeConfiguration(
                baseURL: URL(string: "https://dashscope.aliyuncs.com")!,
                model: "qwen3-asr-flash-realtime",
                apiKey: "test-api-key",
                finalizationTimeout: 1
            )
        )
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

private actor ConnectionCompletionFlag {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

private actor RecordingWebSocketTransport: WebSocketTransport {
    private(set) var connectedRequest: URLRequest?
    private(set) var sentPayloads: [Data] = []
    private(set) var closeCount = 0
    private var incoming: [Result<Data, Error>] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []

    var sentEventTypes: [String] {
        sentPayloads.compactMap { payload in
            guard
                let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else {
                return nil
            }
            return object["type"] as? String
        }
    }

    func connect(request: URLRequest) async throws {
        connectedRequest = request
    }

    func send(data: Data) async throws {
        sentPayloads.append(data)
    }

    func receive() async throws -> Data {
        if !incoming.isEmpty {
            return try incoming.removeFirst().get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func close() async {
        closeCount += 1
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }

    func enqueue(_ data: Data) {
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: data)
        } else {
            incoming.append(.success(data))
        }
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

import XCTest
@testable import PulseType

final class QwenRealtimeProtocolTests: XCTestCase {
    func testBatchQwenModelUsesRealtimeSibling() {
        XCTAssertEqual(
            QwenRealtimeModelResolver.preferredModel(from: "qwen3-asr-flash"),
            "qwen3-asr-flash-realtime"
        )
    }

    func testExplicitRealtimeModelIsPreserved() {
        XCTAssertEqual(
            QwenRealtimeModelResolver.preferredModel(from: "custom-realtime-model"),
            "custom-realtime-model"
        )
    }

    func testLegacyDashScopeHTTPURLBecomesRealtimeWebSocketURL() throws {
        let url = try QwenRealtimeEndpointResolver.resolve(
            baseURL: URL(string: "https://dashscope.aliyuncs.com/api/v1")!,
            model: "qwen3-asr-flash-realtime"
        )

        XCTAssertEqual(
            url.absoluteString,
            "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime"
        )
    }

    func testWorkspaceHostIsPreservedWhenBuildingRealtimeURL() throws {
        let url = try QwenRealtimeEndpointResolver.resolve(
            baseURL: URL(string: "https://workspace.cn-beijing.maas.aliyuncs.com/api/v1")!,
            model: "qwen3-asr-flash-realtime"
        )

        XCTAssertEqual(url.host, "workspace.cn-beijing.maas.aliyuncs.com")
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.path, "/api-ws/v1/realtime")
    }

    func testSessionUpdateUsesLowLatencyChinesePCMAndContext() throws {
        let data = try QwenRealtimeCommandEncoder.sessionUpdate(
            contextText: "PulseType，产品经理，AB-129"
        )
        let root = try XCTUnwrap(jsonObject(data))
        let session = try XCTUnwrap(root["session"] as? [String: Any])
        let transcription = try XCTUnwrap(session["input_audio_transcription"] as? [String: Any])
        let corpus = try XCTUnwrap(transcription["corpus"] as? [String: Any])
        let vad = try XCTUnwrap(session["turn_detection"] as? [String: Any])

        XCTAssertEqual(root["type"] as? String, "session.update")
        XCTAssertEqual(session["input_audio_format"] as? String, "pcm")
        XCTAssertEqual(session["sample_rate"] as? Int, 16_000)
        XCTAssertNil(session["modalities"])
        XCTAssertEqual(transcription["language"] as? String, "zh")
        XCTAssertEqual(corpus["text"] as? String, "PulseType，产品经理，AB-129")
        XCTAssertEqual(vad["type"] as? String, "server_vad")
        XCTAssertEqual(vad["threshold"] as? Double, 0.0)
        XCTAssertEqual(vad["silence_duration_ms"] as? Int, 400)
    }

    func testAudioAppendEncodesOnlyTheCurrentChunk() throws {
        let data = try QwenRealtimeCommandEncoder.audioAppend(Data([0, 1, 2, 3]))
        let root = try XCTUnwrap(jsonObject(data))

        XCTAssertEqual(root["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(root["audio"] as? String, "AAECAw==")
    }

    func testDeltaEventParsesConfirmedTextAndRevisableStash() throws {
        let data = Data(
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item-1","text":"今天天气","stash":"很好"}"#.utf8
        )

        XCTAssertEqual(
            try QwenRealtimeEventParser.parse(data),
            .delta(itemID: "item-1", confirmedText: "今天天气", tentativeText: "很好")
        )
    }

    func testCompletedEventParsesAuthoritativeTranscript() throws {
        let data = Data(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item-1","transcript":"你好，世界。"}"#.utf8
        )

        XCTAssertEqual(
            try QwenRealtimeEventParser.parse(data),
            .completed(itemID: "item-1", transcript: "你好，世界。")
        )
    }

    func testLifecycleEventsMapToProviderNeutralEvents() throws {
        XCTAssertEqual(
            try QwenRealtimeEventParser.parse(Data(#"{"type":"session.updated"}"#.utf8)),
            .sessionReady
        )
        XCTAssertEqual(
            try QwenRealtimeEventParser.parse(
                Data(#"{"type":"input_audio_buffer.speech_started","item_id":"item-2"}"#.utf8)
            ),
            .speechStarted(itemID: "item-2")
        )
        XCTAssertEqual(
            try QwenRealtimeEventParser.parse(Data(#"{"type":"session.finished"}"#.utf8)),
            .sessionFinished
        )
    }

    func testServerErrorIsActionableAndRedactsCredential() throws {
        let secret = "sk-" + String(repeating: "A", count: 20)
        let data = Data(
            #"{"type":"error","error":{"code":"invalid_api_key","message":"bad key \#(secret)"}}"#.utf8
        )

        XCTAssertThrowsError(try QwenRealtimeEventParser.parse(data)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("invalid_api_key"))
            XCTAssertFalse(message.contains(secret))
            XCTAssertTrue(message.contains("[REDACTED]"))
        }
    }

    func testUnrelatedLifecycleEventIsIgnored() throws {
        let data = Data(#"{"type":"conversation.item.created","item":{"id":"item-1"}}"#.utf8)

        XCTAssertNil(try QwenRealtimeEventParser.parse(data))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

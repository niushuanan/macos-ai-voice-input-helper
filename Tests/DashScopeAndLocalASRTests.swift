import XCTest
@testable import PulseType

final class DashScopeAndLocalASRTests: XCTestCase {
    private let fakeAPIKey = "demo_key"

    override func tearDown() {
        DashScopeURLProtocolStub.requestHandler = nil
        super.tearDown()
    }

    func testDashScopeConnectionTesterUsesOfficialEndpointAndParsesTranscript() async {
        let credentialStore = InMemoryCredentialStore()
        try? credentialStore.saveAPIKey(fakeAPIKey, for: "asr")

        let tester = ASRConnectionTester(
            session: makeStubSession(),
            credentialStore: credentialStore
        )

        DashScopeURLProtocolStub.requestHandler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/api/v1/services/aigc/multimodal-generation/generation"
            )
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer \(self.fakeAPIKey)"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/json"
            )

            let body = request.httpBody ?? self.readBodyStream(from: request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["model"] as? String, "qwen3-asr-flash")

            let input = try XCTUnwrap(json["input"] as? [String: Any])
            let messages = try XCTUnwrap(input["messages"] as? [[String: Any]])
            let user = try XCTUnwrap(messages.first { $0["role"] as? String == "user" })
            let content = try XCTUnwrap(user["content"] as? [[String: Any]])
            let audioDataURL = try XCTUnwrap(content.first?["audio"] as? String)
            XCTAssertTrue(audioDataURL.hasPrefix("data:audio/wav;base64,"))

            let parameters = try XCTUnwrap(json["parameters"] as? [String: Any])
            XCTAssertEqual(parameters["result_format"] as? String, "message")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(
                #"{"output":{"choices":[{"message":{"content":[{"text":"本地测试转写"}]}}]}}"#.utf8
            )
            return (response, data)
        }

        let result = await tester.test(
            config: ASRConfig(
                providerType: .dashScopeQwenASR,
                baseURLString: "https://dashscope.aliyuncs.com",
                modelName: "qwen3-asr-flash",
                keyRef: "asr"
            )
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertTrue(result.message.contains("本地测试转写"))
    }

    func testDashScopeConnectionTesterMapsUnauthorizedToKeyHint() async {
        let credentialStore = InMemoryCredentialStore()
        try? credentialStore.saveAPIKey(fakeAPIKey, for: "asr")

        let tester = ASRConnectionTester(
            session: makeStubSession(),
            credentialStore: credentialStore
        )

        DashScopeURLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"message":"Invalid API Key"}"#.utf8)
            return (response, data)
        }

        let result = await tester.test(
            config: ASRConfig(
                providerType: .dashScopeQwenASR,
                baseURLString: "https://dashscope.aliyuncs.com",
                modelName: "qwen3-asr-flash",
                keyRef: "asr"
            )
        )

        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.httpStatus, 401)
        XCTAssertTrue(result.hint.contains("密钥"))
    }

    func testDashScopeConnectionTesterParsesTopLevelChoicesMessageString() async {
        let credentialStore = InMemoryCredentialStore()
        try? credentialStore.saveAPIKey(fakeAPIKey, for: "asr")

        let tester = ASRConnectionTester(
            session: makeStubSession(),
            credentialStore: credentialStore
        )

        DashScopeURLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(
                #"{"choices":[{"message":{"content":"这是 choices 字符串结构"}}]}"#.utf8
            )
            return (response, data)
        }

        let result = await tester.test(
            config: ASRConfig(
                providerType: .dashScopeQwenASR,
                baseURLString: "https://dashscope.aliyuncs.com",
                modelName: "qwen3-asr-flash",
                keyRef: "asr"
            )
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertTrue(result.message.contains("choices 字符串结构"))
    }

    func testDashScopeConnectionTesterParsesOutputTextFallback() async {
        let credentialStore = InMemoryCredentialStore()
        try? credentialStore.saveAPIKey(fakeAPIKey, for: "asr")

        let tester = ASRConnectionTester(
            session: makeStubSession(),
            credentialStore: credentialStore
        )

        DashScopeURLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(
                #"{"output":{"text":"这是 output.text 兜底结构"}}"#.utf8
            )
            return (response, data)
        }

        let result = await tester.test(
            config: ASRConfig(
                providerType: .dashScopeQwenASR,
                baseURLString: "https://dashscope.aliyuncs.com",
                modelName: "qwen3-asr-flash",
                keyRef: "asr"
            )
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertTrue(result.message.contains("output.text"))
    }

    func testDashScopeConnectionTesterMapsHTTP200BusinessError() async {
        let credentialStore = InMemoryCredentialStore()
        try? credentialStore.saveAPIKey(fakeAPIKey, for: "asr")

        let tester = ASRConnectionTester(
            session: makeStubSession(),
            credentialStore: credentialStore
        )

        DashScopeURLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(
                #"{"code":"InvalidModel","message":"model qwen3-asr-flash is unavailable"}"#.utf8
            )
            return (response, data)
        }

        let result = await tester.test(
            config: ASRConfig(
                providerType: .dashScopeQwenASR,
                baseURLString: "https://dashscope.aliyuncs.com",
                modelName: "qwen3-asr-flash",
                keyRef: "asr"
            )
        )

        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.httpStatus, 200)
        XCTAssertTrue(result.message.contains("InvalidModel"))
        XCTAssertTrue(result.hint.contains("模型"))
    }

    func testLocalSenseVoiceHealthCheckerFailsWhenModelDirectoryMissing() {
        let result = LocalSenseVoiceHealthChecker.check(
            config: ASRConfig(
                providerType: .localSenseVoice,
                baseURLString: "",
                modelName: "sensevoice-small",
                keyRef: "asr",
                localModelPath: "/tmp/pulsetype-missing-\(UUID().uuidString)"
            )
        )

        XCTAssertEqual(result.status, .failure)
        XCTAssertTrue(result.message.contains("模型目录不存在"))
    }

    func testLocalSenseVoiceHealthCheckerFailsWhenRequiredFilesMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensevoice-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokens.json"))

        let result = LocalSenseVoiceHealthChecker.check(
            config: ASRConfig(
                providerType: .localSenseVoice,
                baseURLString: "",
                modelName: "sensevoice-small",
                keyRef: "asr",
                localModelPath: directory.path
            )
        )

        XCTAssertEqual(result.status, .failure)
        XCTAssertTrue(result.message.contains("model.onnx"))
        XCTAssertTrue(result.message.contains("config.yaml"))
    }

    func testLocalSenseVoiceProviderThrowsProviderFailureForInvalidDirectory() async throws {
        let provider = LocalSenseVoiceProvider()
        let clipURL = try makeTemporaryClipURL()
        defer { try? FileManager.default.removeItem(at: clipURL) }

        do {
            _ = try await provider.transcribe(
                request: SpeechTranscriptionRequest(
                    clip: RecordedAudioClip(
                        id: UUID(),
                        fileURL: clipURL,
                        duration: 0.6,
                        sampleRate: 16_000,
                        createdAt: Date()
                    ),
                    lane: .directDictation,
                    contextSummary: "unit-test"
                ),
                configuration: SpeechProviderConfiguration(
                    profileID: "local-asr",
                    providerType: .localSenseVoice,
                    providerName: "本地 SenseVoice（实验）",
                    modelName: "sensevoice-small",
                    baseURL: URL(string: "https://local.sensevoice")!,
                    localModelPath: "/tmp/pulsetype-missing-\(UUID().uuidString)"
                ),
                apiKey: ""
            )
            XCTFail("Expected provider failure, but got success.")
        } catch let error as SpeechTranscriptionError {
            guard case let .providerFailure(description) = error else {
                XCTFail("Expected provider failure, got: \(error)")
                return
            }
            XCTAssertTrue(description.contains("模型目录不存在"))
        } catch {
            XCTFail("Expected SpeechTranscriptionError, got: \(error)")
        }
    }

    func testParseProviderErrorRedactsSensitiveTokens() throws {
        let token = "sk-" + String(repeating: "a", count: 24)
        let body: [String: String] = [
            "message": "Authorization: Bearer \(token)"
        ]
        let data = try JSONSerialization.data(withJSONObject: body)

        let detail = ASRConnectionTester.parseProviderError(from: data)
        XCTAssertFalse(detail.contains(token))
        XCTAssertTrue(detail.contains("Bearer [REDACTED]"))
        XCTAssertTrue(detail.contains("Authorization:"))
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DashScopeURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func makeTemporaryClipURL() throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-sensevoice-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try Data([0x00, 0x01, 0x02]).write(to: fileURL)
        return fileURL
    }

    private func readBodyStream(from request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return Data() }

        stream.open()
        defer { stream.close() }

        let bufferSize = 4096
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }

        return data
    }
}

private final class InMemoryCredentialStore: ProviderCredentialStore {
    private var storage: [String: String] = [:]

    func loadAPIKey(for profileID: String) throws -> String? {
        storage[profileID]
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {
        storage[profileID] = value
    }

    func deleteAPIKey(for profileID: String) throws {
        storage.removeValue(forKey: profileID)
    }

    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool {
        storage[profileID]?.isEmpty == false
    }
}

private final class DashScopeURLProtocolStub: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "DashScopeURLProtocolStub", code: -1))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

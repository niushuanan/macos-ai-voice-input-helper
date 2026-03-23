import XCTest
@testable import PulseType

final class OpenAIProviderAdapterTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.requestHandler = nil
        super.tearDown()
    }

    func testTranscriptionProviderUsesResolvedEndpointAndParsesJSON() async throws {
        let session = makeStubSession()
        let provider = OpenAITranscriptionProvider(session: session)
        let clipURL = try makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: clipURL) }

        URLProtocolStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertTrue(request.httpBody != nil || request.httpBodyStream != nil)
            let bodyData = self.readBodyData(from: request)
            let bodyText = String(data: bodyData, encoding: .utf8) ?? ""
            XCTAssertFalse(bodyText.contains("name=\"prompt\""))

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"text":"hello from test"}"#.utf8)
            return (response, data)
        }

        let result = try await provider.transcribe(
            request: SpeechTranscriptionRequest(
                clip: RecordedAudioClip(
                    id: UUID(),
                    fileURL: clipURL,
                    duration: 0.8,
                    sampleRate: 44_100,
                    createdAt: Date()
                ),
                lane: .directDictation,
                contextSummary: "unit-test"
            ),
            configuration: SpeechProviderConfiguration(
                profileID: "profile-1",
                providerType: .openAICompatible,
                providerName: "Compatible",
                modelName: "whisper-1",
                baseURL: URL(string: "https://api.example.com/v1/")!
            ),
            apiKey: "test-key"
        )

        XCTAssertEqual(result.transcript, "hello from test")
    }

    func testTranscriptionProviderInjectsPromptFieldWhenDictionaryHintProvided() async throws {
        let session = makeStubSession()
        let provider = OpenAITranscriptionProvider(session: session)
        let clipURL = try makeTemporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: clipURL) }
        let prompt = "用户词典（优先识别以下词条并按原样输出）：\nOpenAI\nDeepSeek"

        URLProtocolStub.requestHandler = { request in
            let bodyData = self.readBodyData(from: request)
            let bodyText = String(data: bodyData, encoding: .utf8) ?? ""
            XCTAssertTrue(bodyText.contains("name=\"prompt\""))
            XCTAssertTrue(bodyText.contains(prompt))

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"text":"ok"}"#.utf8))
        }

        _ = try await provider.transcribe(
            request: SpeechTranscriptionRequest(
                clip: RecordedAudioClip(
                    id: UUID(),
                    fileURL: clipURL,
                    duration: 0.8,
                    sampleRate: 44_100,
                    createdAt: Date()
                ),
                lane: .directDictation,
                contextSummary: "unit-test",
                dictionaryTerms: ["OpenAI", "DeepSeek"],
                dictionaryPromptHint: prompt
            ),
            configuration: SpeechProviderConfiguration(
                profileID: "profile-1",
                providerType: .openAICompatible,
                providerName: "Compatible",
                modelName: "whisper-1",
                baseURL: URL(string: "https://api.example.com/v1/")!
            ),
            apiKey: "test-key"
        )
    }

    func testGenerationProviderUsesResolvedEndpointAndParsesChoice() async throws {
        let session = makeStubSession()
        let provider = OpenAITextGenerationProvider(session: session)

        URLProtocolStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/openai/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"choices":[{"message":{"content":"rewritten text"}}]}"#.utf8)
            return (response, data)
        }

        let result = try await provider.generateText(
            request: TextGenerationRequest(
                systemPrompt: "system",
                userPrompt: "user",
                temperature: 0.2,
                maxOutputTokens: 300
            ),
            configuration: TextGenerationProviderConfiguration(
                profileID: "profile-2",
                providerType: .openAICompatible,
                providerName: "Compatible",
                modelName: "gpt-4o-mini",
                baseURL: URL(string: "https://api.example.com/openai")!
            ),
            apiKey: "test-key"
        )

        XCTAssertEqual(result.outputText, "rewritten text")
    }

    func testASRConnectionTesterUsesOpenAICompatibleEndpoint() async {
        let session = makeStubSession()
        let credentialStore = MemoryCredentialStore()
        try? credentialStore.saveAPIKey("sk-test-000000", for: "asr")
        let tester = ASRConnectionTester(
            session: session,
            credentialStore: credentialStore
        )

        URLProtocolStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-000000")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"text":"连接正常"}"#.utf8)
            return (response, data)
        }

        let result = await tester.test(
            config: ASRConfig(
                providerType: .openAICompatible,
                baseURLString: "https://asr.example.com",
                modelName: "whisper-1",
                keyRef: "asr"
            )
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.httpStatus, 200)
        XCTAssertTrue(result.message.contains("连接正常"))
    }

    func testASRConnectionTesterFailsWhenCredentialMissing() async {
        let tester = ASRConnectionTester(
            session: makeStubSession(),
            credentialStore: MemoryCredentialStore()
        )

        let result = await tester.test(
            config: ASRConfig(
                providerType: .openAICompatible,
                baseURLString: "https://asr.example.com",
                modelName: "whisper-1",
                keyRef: "asr"
            )
        )

        XCTAssertEqual(result.status, .failure)
        XCTAssertTrue(result.message.contains("密钥"))
    }

    func testTextConnectionTesterMaps401ToActionableHint() async {
        let session = makeStubSession()
        let credentialStore = MemoryCredentialStore()
        try? credentialStore.saveAPIKey("sk-text-000000", for: "text")
        let tester = TextConnectionTester(
            session: session,
            credentialStore: credentialStore
        )

        URLProtocolStub.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-text-000000")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"error":{"message":"invalid api key"}}"#.utf8)
            return (response, data)
        }

        let result = await tester.test(
            config: TextConfig(
                providerType: .openAICompatible,
                baseURLString: "https://text.example.com",
                modelName: "gpt-4o-mini",
                keyRef: "text"
            )
        )

        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.httpStatus, 401)
        XCTAssertTrue(result.hint.contains("密钥"))
    }

    private func makeStubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func makeTemporaryAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-test-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        return url
    }

    private func readBodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 4096
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }

        return data
    }
}

private final class MemoryCredentialStore: ProviderCredentialStore {
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

private final class URLProtocolStub: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "URLProtocolStub", code: -1))
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

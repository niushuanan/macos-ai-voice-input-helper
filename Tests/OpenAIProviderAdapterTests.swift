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

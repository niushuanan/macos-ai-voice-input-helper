import XCTest
@testable import PulseType

final class OpenAIEndpointResolverTests: XCTestCase {
    func testTranscriptionURLAppendsVersionWhenMissing() {
        let url = OpenAIEndpointResolver.transcriptionURL(
            baseURL: URL(string: "https://example.com")!
        )

        XCTAssertEqual(url.absoluteString, "https://example.com/v1/audio/transcriptions")
    }

    func testTranscriptionURLAvoidsDuplicateVersion() {
        let url = OpenAIEndpointResolver.transcriptionURL(
            baseURL: URL(string: "https://example.com/v1/")!
        )

        XCTAssertEqual(url.absoluteString, "https://example.com/v1/audio/transcriptions")
    }

    func testChatCompletionsURLKeepsCustomPrefixAndAddsVersion() {
        let url = OpenAIEndpointResolver.chatCompletionsURL(
            baseURL: URL(string: "https://example.com/openai")!
        )

        XCTAssertEqual(url.absoluteString, "https://example.com/openai/v1/chat/completions")
    }
}

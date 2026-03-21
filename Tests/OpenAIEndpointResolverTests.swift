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

    func testChatCompletionsURLAvoidsDuplicateVersion() {
        let url = OpenAIEndpointResolver.chatCompletionsURL(
            baseURL: URL(string: "https://example.com/openai/v1")!
        )

        XCTAssertEqual(url.absoluteString, "https://example.com/openai/v1/chat/completions")
    }

    func testValidatorRejectsEmptyModel() {
        let message = ProviderConfigurationValidator.validationMessage(
            providerType: .openAICompatible,
            baseURLString: "https://api.example.com",
            modelName: "   "
        )

        XCTAssertEqual(message, "模型名不能为空。")
    }

    func testValidatorRejectsInvalidURL() {
        let message = ProviderConfigurationValidator.validationMessage(
            providerType: .openAICompatible,
            baseURLString: "not a url",
            modelName: "whisper-1"
        )

        XCTAssertEqual(message, "接口地址（Base URL）无效。")
    }

    func testValidatorAcceptsOfficialProviderWithoutCustomBaseURL() {
        let message = ProviderConfigurationValidator.validationMessage(
            providerType: .openAI,
            baseURLString: "",
            modelName: "gpt-4o-mini"
        )

        XCTAssertNil(message)
    }
}

import Foundation

struct OpenAITextGenerationProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAI, .openAICompatible]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> TextGenerationResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw RewriteProviderError.generationFailed(description: "API key is empty.")
        }

        let payload = ChatCompletionsPayload(
            model: configuration.modelName,
            temperature: request.temperature,
            maxTokens: request.maxOutputTokens,
            messages: [
                .init(role: "system", content: request.systemPrompt),
                .init(role: "user", content: request.userPrompt)
            ]
        )

        var urlRequest = URLRequest(
            url: OpenAIEndpointResolver.chatCompletionsURL(baseURL: configuration.baseURL)
        )
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 70
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw RewriteProviderError.generationFailed(description: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RewriteProviderError.generationFailed(description: "Invalid HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            if
                let errorEnvelope = try? JSONDecoder().decode(ChatCompletionsErrorEnvelope.self, from: data),
                let message = errorEnvelope.error.message
            {
                throw RewriteProviderError.generationFailed(
                    description: "HTTP \(http.statusCode): \(message)"
                )
            }

            let fallback = String(data: data, encoding: .utf8) ?? "empty error payload"
            throw RewriteProviderError.generationFailed(
                description: "HTTP \(http.statusCode): \(fallback)"
            )
        }

        guard
            let responsePayload = try? JSONDecoder().decode(ChatCompletionsResponse.self, from: data),
            let first = responsePayload.choices.first,
            !first.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw RewriteProviderError.generationFailed(description: "Missing text from model response.")
        }

        return TextGenerationResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            outputText: first.message.content
        )
    }
}

private struct ChatCompletionsPayload: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let temperature: Double
    let maxTokens: Int?
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case temperature
        case maxTokens = "max_tokens"
        case messages
    }
}

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct ChatCompletionsErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let message: String?
    }

    let error: Payload
}

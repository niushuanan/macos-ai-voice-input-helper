import Foundation

struct OpenAITextGenerationProvider: TextGenerationProvider, StreamingTextGenerationProvider {
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
            thinking: resolvedThinkingMode(for: configuration),
            stream: nil,
            streamOptions: nil,
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

    func generateTextStream(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw RewriteProviderError.generationFailed(description: "API key is empty.")
        }

        let payload = ChatCompletionsPayload(
            model: configuration.modelName,
            temperature: request.temperature,
            maxTokens: request.maxOutputTokens,
            thinking: resolvedThinkingMode(for: configuration),
            stream: true,
            streamOptions: .init(includeUsage: true),
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
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw RewriteProviderError.generationFailed(description: "Invalid HTTP response.")
                    }

                    guard (200..<300).contains(http.statusCode) else {
                        let body = try await readFullBody(from: bytes)
                        throw providerError(
                            statusCode: http.statusCode,
                            responseBody: body
                        )
                    }

                    var accumulatedText = ""
                    var sawDone = false
                    for try await line in bytes.lines {
                        guard let payloadLine = ssePayload(from: line) else {
                            continue
                        }

                        if payloadLine == "[DONE]" {
                            sawDone = true
                            break
                        }

                        guard let data = payloadLine.data(using: .utf8) else {
                            continue
                        }

                        let chunk = try decodeStreamChunk(from: data)
                        guard let delta = chunk.deltaText, !delta.isEmpty else {
                            continue
                        }

                        accumulatedText.append(delta)
                        continuation.yield(accumulatedText)
                    }

                    let normalized = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalized.isEmpty else {
                        throw RewriteProviderError.generationFailed(
                            description: sawDone
                                ? "Missing text from model stream."
                                : "Stream ended before any text was produced."
                        )
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func resolvedThinkingMode(
        for configuration: TextGenerationProviderConfiguration
    ) -> ChatCompletionsPayload.ThinkingMode? {
        guard configuration.providerType == .openAICompatible else {
            return nil
        }

        let host = configuration.baseURL.host?.lowercased() ?? ""
        let modelName = configuration.modelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard host.contains("deepseek.com"), modelName.hasPrefix("deepseek-v4-") else {
            return nil
        }

        // `deepseek-chat` 原先对应非思考模式；切到 V4 显式关闭 thinking，保持现有清理/改写时延和输出形态。
        return .init(type: "disabled")
    }

    private func providerError(
        statusCode: Int,
        responseBody: String
    ) -> RewriteProviderError {
        let data = Data(responseBody.utf8)
        if
            let errorEnvelope = try? JSONDecoder().decode(ChatCompletionsErrorEnvelope.self, from: data),
            let message = errorEnvelope.error.message
        {
            return .generationFailed(description: "HTTP \(statusCode): \(message)")
        }

        let fallback = responseBody.isEmpty ? "empty error payload" : responseBody
        return .generationFailed(description: "HTTP \(statusCode): \(fallback)")
    }

    private func readFullBody(
        from bytes: URLSession.AsyncBytes
    ) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func ssePayload(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else {
            return nil
        }
        return trimmed
            .dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeStreamChunk(from data: Data) throws -> ChatCompletionsStreamChunk {
        do {
            return try JSONDecoder().decode(ChatCompletionsStreamChunk.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "invalid stream chunk"
            throw RewriteProviderError.generationFailed(description: "Invalid stream chunk: \(raw)")
        }
    }
}

private struct ChatCompletionsPayload: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ThinkingMode: Encodable {
        let type: String
    }

    struct StreamOptions: Encodable {
        let includeUsage: Bool

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }

    let model: String
    let temperature: Double
    let maxTokens: Int?
    let thinking: ThinkingMode?
    let stream: Bool?
    let streamOptions: StreamOptions?
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case temperature
        case maxTokens = "max_tokens"
        case thinking
        case stream
        case streamOptions = "stream_options"
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

private struct ChatCompletionsStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: ContentPayload?
        }

        let delta: Delta?
    }

    struct ContentPart: Decodable {
        let text: String?
    }

    enum ContentPayload: Decodable {
        case text(String)
        case parts([ContentPart])

        init(from decoder: Decoder) throws {
            let singleValueContainer = try decoder.singleValueContainer()
            if let text = try? singleValueContainer.decode(String.self) {
                self = .text(text)
                return
            }
            if let parts = try? singleValueContainer.decode([ContentPart].self) {
                self = .parts(parts)
                return
            }
            throw DecodingError.typeMismatch(
                ContentPayload.self,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported streaming content payload."
                )
            )
        }

        var textValue: String {
            switch self {
            case let .text(text):
                return text
            case let .parts(parts):
                return parts.compactMap(\.text).joined()
            }
        }
    }

    let choices: [Choice]

    var deltaText: String? {
        choices
            .compactMap { $0.delta?.content?.textValue }
            .joined()
    }
}

import Foundation

struct OpenAITranscriptionProvider: SpeechTranscriptionProvider {
    let supportedProviderTypes: [ProviderType] = [.openAI, .openAICompatible]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(
        request: SpeechTranscriptionRequest,
        configuration: SpeechProviderConfiguration,
        apiKey: String
    ) async throws -> SpeechTranscriptionResult {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw SpeechTranscriptionError.missingAPIKey(providerName: configuration.providerName)
        }

        let fileURL = request.clip.fileURL
        guard let format = OpenAIAudioFormat(fileURL: fileURL) else {
            throw SpeechTranscriptionError.audioFormatUnsupported(fileExtension: fileURL.pathExtension.lowercased())
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL)
        } catch {
            throw SpeechTranscriptionError.providerFailure(description: "无法读取录音文件。")
        }

        var urlRequest = URLRequest(
            url: OpenAIEndpointResolver.transcriptionURL(baseURL: configuration.baseURL)
        )
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("Bearer \(normalizedKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = buildMultipartBody(
            boundary: boundary,
            configuration: configuration,
            fileURL: fileURL,
            audioData: audioData,
            format: format,
            promptHint: request.dictionaryPromptHint
        )

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw SpeechTranscriptionError.cancelled
        } catch let urlError as URLError {
            throw SpeechTranscriptionError.networkFailure(description: urlError.localizedDescription)
        } catch {
            throw SpeechTranscriptionError.networkFailure(description: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechTranscriptionError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw mapProviderError(statusCode: httpResponse.statusCode, data: responseData)
        }

        if let decoded = try? JSONDecoder().decode(OpenAITranscriptionPayload.self, from: responseData) {
            let transcript = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                throw SpeechTranscriptionError.invalidResponse
            }

            return SpeechTranscriptionResult(
                providerType: configuration.providerType,
                providerName: configuration.providerName,
                modelName: configuration.modelName,
                transcript: transcript
            )
        }

        if
            let rawText = String(data: responseData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawText.isEmpty
        {
            if looksLikeJSONPayload(rawText) {
                throw SpeechTranscriptionError.invalidResponse
            }
            return SpeechTranscriptionResult(
                providerType: configuration.providerType,
                providerName: configuration.providerName,
                modelName: configuration.modelName,
                transcript: rawText
            )
        }

        throw SpeechTranscriptionError.invalidResponse
    }

    private func looksLikeJSONPayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    private func buildMultipartBody(
        boundary: String,
        configuration: SpeechProviderConfiguration,
        fileURL: URL,
        audioData: Data,
        format: OpenAIAudioFormat,
        promptHint: String?
    ) -> Data {
        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendUTF8("\(configuration.modelName)\r\n")

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.appendUTF8("json\r\n")

        if let promptHint, !promptHint.isEmpty {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            body.appendUTF8("\(promptHint)\r\n")
        }

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        body.appendUTF8("Content-Type: \(format.mimeType)\r\n\r\n")
        body.append(audioData)
        body.appendUTF8("\r\n")
        body.appendUTF8("--\(boundary)--\r\n")
        return body
    }

    private func mapProviderError(statusCode: Int, data: Data) -> SpeechTranscriptionError {
        if
            let envelope = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data),
            let message = envelope.error.message?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        {
            return .providerFailure(description: "HTTP \(statusCode): \(message)")
        }

        if
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        {
            return .providerFailure(description: "HTTP \(statusCode): \(text)")
        }

        return .providerFailure(description: "HTTP \(statusCode) with empty error payload.")
    }
}

private struct OpenAITranscriptionPayload: Decodable {
    let text: String
}

private struct OpenAIErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let message: String?
    }

    let error: Payload
}

private enum OpenAIAudioFormat {
    case m4a
    case wav
    case mp3
    case mp4
    case mpeg
    case mpga
    case webm

    init?(fileURL: URL) {
        switch fileURL.pathExtension.lowercased() {
        case "m4a":
            self = .m4a
        case "wav":
            self = .wav
        case "mp3":
            self = .mp3
        case "mp4":
            self = .mp4
        case "mpeg":
            self = .mpeg
        case "mpga":
            self = .mpga
        case "webm":
            self = .webm
        default:
            return nil
        }
    }

    var mimeType: String {
        switch self {
        case .m4a:
            return "audio/m4a"
        case .wav:
            return "audio/wav"
        case .mp3:
            return "audio/mpeg"
        case .mp4:
            return "audio/mp4"
        case .mpeg:
            return "audio/mpeg"
        case .mpga:
            return "audio/mpeg"
        case .webm:
            return "audio/webm"
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}

struct DashScopeQwenASRProvider: SpeechTranscriptionProvider {
    let supportedProviderTypes: [ProviderType] = [.dashScopeQwenASR]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(
        request: SpeechTranscriptionRequest,
        configuration: SpeechProviderConfiguration,
        apiKey: String
    ) async throws -> SpeechTranscriptionResult {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw SpeechTranscriptionError.missingAPIKey(providerName: configuration.providerName)
        }

        let fileURL = request.clip.fileURL
        guard let format = DashScopeAudioFormat(fileURL: fileURL) else {
            throw SpeechTranscriptionError.audioFormatUnsupported(fileExtension: fileURL.pathExtension.lowercased())
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL)
        } catch {
            throw SpeechTranscriptionError.providerFailure(description: "无法读取录音文件。")
        }

        let endpoint = DashScopeEndpointResolver.generationURL(baseURL: configuration.baseURL)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 70
        urlRequest.setValue("Bearer \(normalizedKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = DashScopeASRPayload(
            model: configuration.modelName,
            input: .init(
                messages: [
                    .init(role: "system", content: [.text(request.dictionaryPromptHint ?? "")]),
                    .init(
                        role: "user",
                        content: [
                            .audio(
                                "data:\(format.mimeType);base64,\(audioData.base64EncodedString())"
                            )
                        ]
                    )
                ]
            ),
            parameters: .init(
                resultFormat: "message",
                asrOptions: .init(enableITN: false)
            )
        )

        do {
            urlRequest.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw SpeechTranscriptionError.providerFailure(description: "请求编码失败。")
        }

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw SpeechTranscriptionError.cancelled
        } catch let urlError as URLError {
            throw SpeechTranscriptionError.networkFailure(description: urlError.localizedDescription)
        } catch {
            throw SpeechTranscriptionError.networkFailure(description: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechTranscriptionError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = ASRConnectionTester.parseProviderError(from: responseData)
            throw SpeechTranscriptionError.providerFailure(
                description: "HTTP \(httpResponse.statusCode): \(detail)"
            )
        }

        let transcript = parseTranscript(from: responseData)
        guard !transcript.isEmpty else {
            if let businessError = DashScopeResponseParser.businessError(from: responseData) {
                throw SpeechTranscriptionError.providerFailure(
                    description: businessError.displayMessage
                )
            }
            throw SpeechTranscriptionError.invalidResponse
        }

        return SpeechTranscriptionResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            transcript: transcript
        )
    }

    private func parseTranscript(from data: Data) -> String {
        DashScopeResponseParser.transcript(from: data)
    }
}

private enum DashScopeAudioFormat {
    case m4a
    case wav
    case mp3
    case mp4
    case mpeg
    case mpga
    case webm

    init?(fileURL: URL) {
        switch fileURL.pathExtension.lowercased() {
        case "m4a":
            self = .m4a
        case "wav":
            self = .wav
        case "mp3":
            self = .mp3
        case "mp4":
            self = .mp4
        case "mpeg":
            self = .mpeg
        case "mpga":
            self = .mpga
        case "webm":
            self = .webm
        default:
            return nil
        }
    }

    var mimeType: String {
        switch self {
        case .m4a:
            return "audio/m4a"
        case .wav:
            return "audio/wav"
        case .mp3, .mpeg, .mpga:
            return "audio/mpeg"
        case .mp4:
            return "audio/mp4"
        case .webm:
            return "audio/webm"
        }
    }
}

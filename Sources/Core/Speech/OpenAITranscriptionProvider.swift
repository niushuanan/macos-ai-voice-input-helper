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
            throw SpeechTranscriptionError.providerFailure(description: "Could not read recorded audio file.")
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
            format: format
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
            return SpeechTranscriptionResult(
                providerType: configuration.providerType,
                providerName: configuration.providerName,
                modelName: configuration.modelName,
                transcript: rawText
            )
        }

        throw SpeechTranscriptionError.invalidResponse
    }

    private func buildMultipartBody(
        boundary: String,
        configuration: SpeechProviderConfiguration,
        fileURL: URL,
        audioData: Data,
        format: OpenAIAudioFormat
    ) -> Data {
        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendUTF8("\(configuration.modelName)\r\n")

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.appendUTF8("json\r\n")

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

import Foundation

struct ASRConnectionTester {
    private let session: URLSession
    private let credentialStore: ProviderCredentialStore

    init(
        session: URLSession = .shared,
        credentialStore: ProviderCredentialStore
    ) {
        self.session = session
        self.credentialStore = credentialStore
    }

    func test(config: ASRConfig) async -> ConnectionTestResult {
        if let validationMessage = ProviderConfigurationValidator.validationMessage(
            providerType: config.providerType,
            baseURLString: config.baseURLString,
            modelName: config.modelName
        ) {
            return .failure(
                message: "语音识别配置校验失败：\(validationMessage)",
                hint: "请检查接口地址和模型名。"
            )
        }

        let apiKey: String
        if config.providerType.requiresAPIKey {
            do {
                let loaded = (try credentialStore.loadAPIKey(for: config.keyRef) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !loaded.isEmpty else {
                    return .failure(
                        message: "语音识别 API 密钥为空。",
                        hint: "请先填写并保存 API 密钥，再点测试。"
                    )
                }
                apiKey = loaded
            } catch {
                return .failure(
                    message: "无法读取语音识别 API 密钥：\(error.localizedDescription)",
                    hint: "请重新保存密钥后重试。"
                )
            }
        } else {
            apiKey = ""
        }

        guard
            let baseURL = ProviderConfigurationValidator.resolvedBaseURL(
                providerType: config.providerType,
                baseURLString: config.baseURLString
            )
        else {
            return .failure(
                message: "语音识别接口地址无效。",
                hint: "请填写以 http 或 https 开头的地址。"
            )
        }

        let audioData = DiagnosticAudioSample.makeWaveData()
        switch config.providerType {
        case .dashScopeQwenASR:
            return await testDashScope(
                config: config,
                baseURL: baseURL,
                apiKey: apiKey,
                audioData: audioData
            )
        case .localSenseVoice:
            return LocalSenseVoiceHealthChecker.check(config: config)
        case .openAI, .openAICompatible:
            return await testOpenAICompatible(
                config: config,
                baseURL: baseURL,
                apiKey: apiKey,
                audioData: audioData
            )
        }
    }

    private func testOpenAICompatible(
        config: ASRConfig,
        baseURL: URL,
        apiKey: String,
        audioData: Data
    ) async -> ConnectionTestResult {
        let endpoint = OpenAIEndpointResolver.transcriptionURL(baseURL: baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            modelName: config.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            audioData: audioData
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(
                    message: "语音识别测试失败：无效 HTTP 响应。",
                    hint: "请检查接口地址是否正确。"
                )
            }

            if (200..<300).contains(http.statusCode) {
                let transcript = Self.parseASRTranscript(from: data)
                if transcript.isEmpty {
                    return .success(
                        message: "语音识别接口可达，测试音频未识别到有效语音内容。",
                        hint: "接口连通正常；可用真实语音再测一次文本识别效果。",
                        httpStatus: http.statusCode
                    )
                }
                return .success(
                    message: "语音识别测试成功：\(transcript)",
                    hint: "接口、模型与密钥均可用。",
                    httpStatus: http.statusCode
                )
            }

            let detail = Self.parseProviderError(from: data)
            return .failure(
                message: "语音识别测试失败：HTTP \(http.statusCode) \(detail)",
                hint: ConnectionTestHintResolver.hint(for: http.statusCode),
                httpStatus: http.statusCode
            )
        } catch let urlError as URLError {
            return .failure(
                message: "语音识别测试失败：网络异常 \(urlError.localizedDescription)",
                hint: "请检查网络、代理或接口地址是否可访问。"
            )
        } catch {
            return .failure(
                message: "语音识别测试失败：\(error.localizedDescription)",
                hint: "请稍后重试，如反复失败请检查地址与密钥。"
            )
        }
    }

    private func testDashScope(
        config: ASRConfig,
        baseURL: URL,
        apiKey: String,
        audioData: Data
    ) async -> ConnectionTestResult {
        let endpoint = DashScopeEndpointResolver.generationURL(baseURL: baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(
                DashScopeASRPayload(
                    model: config.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                    input: .init(
                        messages: [
                            .init(role: "system", content: [.text("")]),
                            .init(
                                role: "user",
                                content: [
                                    .audio("data:audio/wav;base64,\(audioData.base64EncodedString())")
                                ]
                            )
                        ]
                    ),
                    parameters: .init(
                        resultFormat: "message",
                        asrOptions: .init(enableITN: false)
                    )
                )
            )
        } catch {
            return .failure(
                message: "语音识别测试失败：请求编码异常。",
                hint: "请检查模型名后重试。"
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(
                    message: "语音识别测试失败：无效 HTTP 响应。",
                    hint: "请检查接口地址是否正确。"
                )
            }

            if (200..<300).contains(http.statusCode) {
                let transcript = Self.parseDashScopeTranscript(from: data)
                if transcript.isEmpty {
                    if let businessError = DashScopeResponseParser.businessError(from: data) {
                        return .failure(
                            message: "语音识别测试失败：\(businessError.displayMessage)",
                            hint: Self.hintForDashScopeBusinessError(businessError),
                            httpStatus: http.statusCode
                        )
                    }
                    return .success(
                        message: "语音识别接口可达，测试音频未识别到有效语音内容。",
                        hint: "接口连通正常；可用真实语音再测一次文本识别效果。",
                        httpStatus: http.statusCode
                    )
                }
                return .success(
                    message: "语音识别测试成功：\(transcript)",
                    hint: "接口、模型与密钥均可用。",
                    httpStatus: http.statusCode
                )
            }

            let detail = Self.parseProviderError(from: data)
            return .failure(
                message: "语音识别测试失败：HTTP \(http.statusCode) \(detail)",
                hint: ConnectionTestHintResolver.hint(for: http.statusCode),
                httpStatus: http.statusCode
            )
        } catch let urlError as URLError {
            return .failure(
                message: "语音识别测试失败：网络异常 \(urlError.localizedDescription)",
                hint: "请检查网络、代理或接口地址是否可访问。"
            )
        } catch {
            return .failure(
                message: "语音识别测试失败：\(error.localizedDescription)",
                hint: "请稍后重试，如反复失败请检查地址与密钥。"
            )
        }
    }

    private static func multipartBody(
        boundary: String,
        modelName: String,
        audioData: Data
    ) -> Data {
        var body = Data()
        body.appendUTF8Bytes("--\(boundary)\r\n")
        body.appendUTF8Bytes("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendUTF8Bytes("\(modelName)\r\n")
        body.appendUTF8Bytes("--\(boundary)\r\n")
        body.appendUTF8Bytes("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.appendUTF8Bytes("json\r\n")
        body.appendUTF8Bytes("--\(boundary)\r\n")
        body.appendUTF8Bytes("Content-Disposition: form-data; name=\"file\"; filename=\"pulse-test.wav\"\r\n")
        body.appendUTF8Bytes("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.appendUTF8Bytes("\r\n")
        body.appendUTF8Bytes("--\(boundary)--\r\n")
        return body
    }

    private static func parseASRTranscript(from data: Data) -> String {
        if
            let payload = try? JSONDecoder().decode(ConnectionTestTranscriptionPayload.self, from: data),
            !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func parseDashScopeTranscript(from data: Data) -> String {
        DashScopeResponseParser.transcript(from: data)
    }

    private static func hintForDashScopeBusinessError(_ error: DashScopeBusinessError) -> String {
        let probe = "\(error.code ?? "") \(error.message)".lowercased()
        if probe.contains("api key") || probe.contains("accesskey") || probe.contains("token") || probe.contains("密钥") {
            return "请检查 API 密钥是否正确、是否仍有效。"
        }
        if probe.contains("model") || probe.contains("模型") {
            return "请确认模型名与当前账号可用模型一致。"
        }
        if probe.contains("quota") || probe.contains("余额") || probe.contains("frequency") || probe.contains("rate") || probe.contains("429") {
            return "请检查额度与频率限制，稍后重试。"
        }
        if probe.contains("network") || probe.contains("timeout") || probe.contains("连接") {
            return "请检查网络、代理以及接口地址可达性。"
        }
        return "请检查模型名、密钥、额度与网络后重试。"
    }

    static func parseProviderError(from data: Data) -> String {
        if let businessError = DashScopeResponseParser.businessError(from: data) {
            return redactSensitiveText(businessError.displayMessage)
        }

        if
            let payload = try? JSONDecoder().decode(ConnectionTestErrorEnvelope.self, from: data),
            let message = payload.error.message?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        {
            return redactSensitiveText(message)
        }

        if
            let payload = try? JSONDecoder().decode(DashScopeSimpleErrorEnvelope.self, from: data),
            let message = payload.message?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        {
            return redactSensitiveText(message)
        }

        let fallback = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !fallback.isEmpty else {
            return "无错误详情"
        }
        return redactSensitiveText(fallback)
    }

    static func redactSensitiveText(_ text: String) -> String {
        var output = text
        output = replaceRegex(
            pattern: #"(?i)(Authorization\s*:\s*Bearer\s+)[A-Za-z0-9._\-]+"#,
            template: "$1[REDACTED]",
            in: output
        )
        output = replaceRegex(
            pattern: #"\bBearer\s+[A-Za-z0-9._\-]{20,}\b"#,
            template: "Bearer [REDACTED]",
            in: output
        )
        output = replaceRegex(
            pattern: #"\bsk-[A-Za-z0-9]{10,}\b"#,
            template: "sk-[REDACTED]",
            in: output
        )
        return output
    }

    private static func replaceRegex(
        pattern: String,
        template: String,
        in text: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}

struct TextConnectionTester {
    private let session: URLSession
    private let credentialStore: ProviderCredentialStore

    init(
        session: URLSession = .shared,
        credentialStore: ProviderCredentialStore
    ) {
        self.session = session
        self.credentialStore = credentialStore
    }

    func test(config: TextConfig) async -> ConnectionTestResult {
        if let validationMessage = ProviderConfigurationValidator.validationMessage(
            providerType: config.providerType,
            baseURLString: config.baseURLString,
            modelName: config.modelName
        ) {
            return .failure(
                message: "文本模型配置校验失败：\(validationMessage)",
                hint: "请检查接口地址和模型名。"
            )
        }

        let apiKey: String
        do {
            let loaded = (try credentialStore.loadAPIKey(for: config.keyRef) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !loaded.isEmpty else {
                return .failure(
                    message: "文本模型 API 密钥为空。",
                    hint: "请先填写并保存 API 密钥，再点测试。"
                )
            }
            apiKey = loaded
        } catch {
            return .failure(
                message: "无法读取文本模型 API 密钥：\(error.localizedDescription)",
                hint: "请重新保存密钥后重试。"
            )
        }

        guard
            let baseURL = ProviderConfigurationValidator.resolvedBaseURL(
                providerType: config.providerType,
                baseURLString: config.baseURLString
            )
        else {
            return .failure(
                message: "文本模型接口地址无效。",
                hint: "请填写以 http 或 https 开头的地址。"
            )
        }

        let endpoint = OpenAIEndpointResolver.chatCompletionsURL(baseURL: baseURL)
        let payload = TextConnectionPayload(
            model: config.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            thinking: resolvedThinkingMode(for: config),
            messages: [
                .init(role: "system", content: "你是连接测试助手。"),
                .init(role: "user", content: "请只回复“连接正常”。")
            ]
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            return .failure(
                message: "文本模型测试失败：请求编码异常。",
                hint: "请检查模型名后重试。"
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(
                    message: "文本模型测试失败：无效 HTTP 响应。",
                    hint: "请检查接口地址是否正确。"
                )
            }

            if (200..<300).contains(http.statusCode) {
                guard let output = Self.parseTextOutput(from: data) else {
                    return .failure(
                        message: "文本模型接口可达，但返回内容无法解析。",
                        hint: "请确认接口兼容 OpenAI `/v1/chat/completions`。",
                        httpStatus: http.statusCode
                    )
                }
                return .success(
                    message: "文本模型测试成功：\(output)",
                    hint: "接口、模型与密钥均可用。",
                    httpStatus: http.statusCode
                )
            }

            let detail = ASRConnectionTester.parseProviderError(from: data)
            return .failure(
                message: "文本模型测试失败：HTTP \(http.statusCode) \(detail)",
                hint: ConnectionTestHintResolver.hint(for: http.statusCode),
                httpStatus: http.statusCode
            )
        } catch let urlError as URLError {
            return .failure(
                message: "文本模型测试失败：网络异常 \(urlError.localizedDescription)",
                hint: "请检查网络、代理或接口地址是否可访问。"
            )
        } catch {
            return .failure(
                message: "文本模型测试失败：\(error.localizedDescription)",
                hint: "请稍后重试，如反复失败请检查地址与密钥。"
            )
        }
    }

    private static func parseTextOutput(from data: Data) -> String? {
        guard
            let response = try? JSONDecoder().decode(TextConnectionResponse.self, from: data),
            let first = response.choices.first?.message.content
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !first.isEmpty
        else {
            return nil
        }
        return first
    }

    private func resolvedThinkingMode(for config: TextConfig) -> TextConnectionPayload.ThinkingMode? {
        guard config.providerType == .openAICompatible else {
            return nil
        }

        let normalizedBaseURL = config.baseURLString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedModel = config.modelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedBaseURL.contains("api.deepseek.com"), normalizedModel.hasPrefix("deepseek-v4-") else {
            return nil
        }

        return .init(type: "disabled")
    }
}

private enum ConnectionTestHintResolver {
    static func hint(for statusCode: Int) -> String {
        switch statusCode {
        case 401:
            return "密钥无效，请重新粘贴 API 密钥。"
        case 403:
            return "账号权限不足，请确认模型权限或组织策略。"
        case 404:
            return "地址或模型名可能不对，请检查 Base URL 与模型名。"
        case 429:
            return "额度或频率受限，请检查余额或稍后重试。"
        case 500...599:
            return "服务端暂时异常，可稍后重试。"
        default:
            return "请检查密钥、模型名、接口地址与账号额度。"
        }
    }
}

private struct TextConnectionPayload: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ThinkingMode: Encodable {
        let type: String
    }

    let model: String
    let thinking: ThinkingMode?
    let messages: [Message]
}

private struct TextConnectionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private enum DiagnosticAudioSample {
    static func makeWaveData(
        sampleRate: Int = 16_000,
        duration: Double = 0.6,
        frequency: Double = 440
    ) -> Data {
        if let bundled = bundledSpeechSampleData() {
            return bundled
        }

        let sampleCount = max(1, Int(Double(sampleRate) * duration))
        var pcmData = Data(capacity: sampleCount * MemoryLayout<Int16>.size)
        let amplitude = 0.2

        for index in 0..<sampleCount {
            let angle = 2.0 * Double.pi * frequency * Double(index) / Double(sampleRate)
            let value = Int16(max(-1, min(1, sin(angle) * amplitude)) * Double(Int16.max))
            var littleEndian = value.littleEndian
            pcmData.append(Data(bytes: &littleEndian, count: MemoryLayout<Int16>.size))
        }

        let byteRate = sampleRate * MemoryLayout<Int16>.size
        let blockAlign = MemoryLayout<Int16>.size
        let dataLength = pcmData.count
        let totalLength = 36 + dataLength

        var wave = Data()
        wave.appendUTF8Bytes("RIFF")
        wave.appendUInt32(UInt32(totalLength))
        wave.appendUTF8Bytes("WAVE")
        wave.appendUTF8Bytes("fmt ")
        wave.appendUInt32(16)
        wave.appendUInt16(1)
        wave.appendUInt16(1)
        wave.appendUInt32(UInt32(sampleRate))
        wave.appendUInt32(UInt32(byteRate))
        wave.appendUInt16(UInt16(blockAlign))
        wave.appendUInt16(16)
        wave.appendUTF8Bytes("data")
        wave.appendUInt32(UInt32(dataLength))
        wave.append(pcmData)
        return wave
    }

    private static func bundledSpeechSampleData() -> Data? {
        for bundle in candidateBundles {
            if
                let url = bundle.url(forResource: "diagnostic-voice-zh", withExtension: "wav"),
                let data = try? Data(contentsOf: url),
                data.count > 44
            {
                return data
            }
        }
        return nil
    }

    private static var candidateBundles: [Bundle] {
        [.main, Bundle(for: DiagnosticAudioSampleBundleProbe.self)]
    }
}

private final class DiagnosticAudioSampleBundleProbe: NSObject {}

private struct ConnectionTestTranscriptionPayload: Decodable {
    let text: String
}

private struct ConnectionTestErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let message: String?
    }

    let error: Payload
}

private struct DashScopeSimpleErrorEnvelope: Decodable {
    let message: String?
}

private extension Data {
    mutating func appendUTF8Bytes(_ value: String) {
        append(Data(value.utf8))
    }

    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt32>.size))
    }
}

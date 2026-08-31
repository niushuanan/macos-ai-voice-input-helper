import Foundation

enum QwenRealtimeModelResolver {
    static func preferredModel(from configuredModel: String) -> String {
        let normalized = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.localizedCaseInsensitiveContains("realtime") else {
            return "qwen3-asr-flash-realtime"
        }
        return normalized
    }
}

enum QwenRealtimeEndpointResolver {
    static func resolve(baseURL: URL, model: String) throws -> URL {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else {
            throw VoiceKernelFailure.invalidEndpoint("模型名为空")
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw VoiceKernelFailure.invalidEndpoint(baseURL.absoluteString)
        }
        guard components.host?.isEmpty == false else {
            throw VoiceKernelFailure.invalidEndpoint(baseURL.absoluteString)
        }

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "wss", "ws":
            break
        default:
            throw VoiceKernelFailure.invalidEndpoint(baseURL.absoluteString)
        }

        components.path = "/api-ws/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: normalizedModel)]
        components.fragment = nil

        guard let url = components.url else {
            throw VoiceKernelFailure.invalidEndpoint(baseURL.absoluteString)
        }
        return url
    }
}

enum QwenRealtimeCommandEncoder {
    private static let maximumContextCharacters = 12_000

    static func sessionUpdate(contextText: String) throws -> Data {
        let normalizedContext = String(
            contextText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maximumContextCharacters)
        )

        var transcription: [String: Any] = ["language": "zh"]
        if !normalizedContext.isEmpty {
            transcription["corpus"] = ["text": normalizedContext]
        }

        return try encode([
            "event_id": makeEventID(),
            "type": "session.update",
            "session": [
                "input_audio_format": "pcm",
                "sample_rate": 16_000,
                "input_audio_transcription": transcription,
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.0,
                    "silence_duration_ms": 400
                ]
            ]
        ])
    }

    static func audioAppend(_ pcmData: Data) throws -> Data {
        try encode([
            "event_id": makeEventID(),
            "type": "input_audio_buffer.append",
            "audio": pcmData.base64EncodedString()
        ])
    }

    static func finish() throws -> Data {
        try encode([
            "event_id": makeEventID(),
            "type": "session.finish"
        ])
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw VoiceKernelFailure.invalidServerEvent("无法编码客户端事件")
        }
    }

    private static func makeEventID() -> String {
        "event_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}

enum QwenRealtimeEventParser {
    static func parse(_ data: Data) throws -> StreamingTranscriptEvent? {
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw VoiceKernelFailure.invalidServerEvent("响应不是 JSON object")
            }
            object = decoded
        } catch let failure as VoiceKernelFailure {
            throw failure
        } catch {
            throw VoiceKernelFailure.invalidServerEvent("JSON 解析失败")
        }

        guard let type = normalizedString(object["type"]) else {
            throw VoiceKernelFailure.invalidServerEvent("缺少 type")
        }

        switch type {
        case "session.updated":
            return .sessionReady

        case "input_audio_buffer.speech_started":
            return .speechStarted(itemID: normalizedString(object["item_id"]))

        case "conversation.item.input_audio_transcription.delta",
             "conversation.item.input_audio_transcription.text":
            let itemID = try requiredString(object["item_id"], field: "item_id")
            return .delta(
                itemID: itemID,
                confirmedText: normalizedStringAllowingEmpty(object["text"]),
                tentativeText: normalizedStringAllowingEmpty(object["stash"])
            )

        case "conversation.item.input_audio_transcription.completed":
            let itemID = try requiredString(object["item_id"], field: "item_id")
            return .completed(
                itemID: itemID,
                transcript: normalizedStringAllowingEmpty(object["transcript"])
            )

        case "session.finished":
            return .sessionFinished

        case "error", "conversation.item.input_audio_transcription.failed":
            throw providerFailure(from: object)

        default:
            return nil
        }
    }

    private static func providerFailure(from object: [String: Any]) -> VoiceKernelFailure {
        let errorObject = object["error"] as? [String: Any]
        let code = normalizedString(errorObject?["code"])
            ?? normalizedString(errorObject?["type"])
            ?? "unknown_error"
        let rawMessage = normalizedString(errorObject?["message"])
            ?? "服务端未提供错误详情"
        return .provider(
            code: code,
            message: ASRConnectionTester.redactSensitiveText(rawMessage)
        )
    }

    private static func requiredString(_ value: Any?, field: String) throws -> String {
        guard let value = normalizedString(value) else {
            throw VoiceKernelFailure.invalidServerEvent("缺少 \(field)")
        }
        return value
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedStringAllowingEmpty(_ value: Any?) -> String {
        guard let string = value as? String else {
            return ""
        }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

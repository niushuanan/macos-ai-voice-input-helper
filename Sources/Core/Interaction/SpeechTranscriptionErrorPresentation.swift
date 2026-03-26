import Foundation

enum SpeechTranscriptionErrorPresentation {
    static func actionableMessage(for error: SpeechTranscriptionError) -> String {
        switch error {
        case let .missingAPIKey(providerName):
            return "\(providerName) 缺少 API 密钥，请在设置页服务商配置中填写。"
        case let .networkFailure(description):
            return "转写时出现网络问题，请检查网络后重试。（\(description)）"
        case let .providerFailure(description):
            return "转写请求失败。\(providerFailureHint(from: description))（\(description)）"
        case let .audioFormatUnsupported(fileExtension):
            return "录音格式 \(fileExtension) 不支持，请重新录音后再试。"
        case .invalidResponse:
            return "服务商返回内容无法解析，可先重试一次，仍失败请更换模型。"
        case .cancelled:
            return "转写已取消。"
        }
    }

    static func finalErrorMessage(
        for error: SpeechTranscriptionError,
        traceID: String,
        attempts: Int
    ) -> String {
        let message = actionableMessage(for: error)
        if case .invalidResponse = error, attempts >= 2 {
            return "\(message)（traceID: \(traceID)）"
        }
        return message
    }

    static func errorType(for error: SpeechTranscriptionError) -> String {
        switch error {
        case .missingAPIKey:
            return "missingAPIKey"
        case .audioFormatUnsupported:
            return "audioFormatUnsupported"
        case .networkFailure:
            return "networkFailure"
        case .providerFailure:
            return "providerFailure"
        case .invalidResponse:
            return "invalidResponse"
        case .cancelled:
            return "cancelled"
        }
    }

    static func httpStatus(from error: SpeechTranscriptionError) -> Int? {
        switch error {
        case let .networkFailure(description):
            return httpStatus(from: description)
        case let .providerFailure(description):
            return httpStatus(from: description)
        case .missingAPIKey, .audioFormatUnsupported, .invalidResponse, .cancelled:
            return nil
        }
    }

    static func httpStatus(from text: String) -> Int? {
        guard
            let regex = try? NSRegularExpression(pattern: #"HTTP\s+(\d{3})"#, options: .caseInsensitive),
            let match = regex.firstMatch(
                in: text,
                options: [],
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            ),
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[range])
    }

    static func providerFailureHint(from description: String) -> String {
        let lowered = description.lowercased()
        if lowered.contains("401") || lowered.contains("unauthorized") || lowered.contains("invalid api key") {
            return "请检查 API 密钥与服务商类型。"
        }
        if lowered.contains("403") || lowered.contains("forbidden") {
            return "请检查账号是否有该模型的调用权限。"
        }
        if lowered.contains("404") || lowered.contains("model") {
            return "请核对模型名与 base URL。"
        }
        if lowered.contains("429") || lowered.contains("rate limit") {
            return "触发频率限制，可稍后再试或切换模型/服务商。"
        }
        if lowered.contains("500") || lowered.contains("502") || lowered.contains("503") || lowered.contains("504") {
            return "服务商接口当前不稳定，请稍后再试。"
        }
        return "请检查 Key、模型、接口地址与额度。"
    }
}

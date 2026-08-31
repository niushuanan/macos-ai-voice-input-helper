import Foundation

struct VoiceSessionContext: Equatable {
    let asrContextText: String
    let semanticContext: SemanticEditorContext?

    init(
        asrContextText: String,
        semanticContext: SemanticEditorContext? = nil
    ) {
        self.asrContextText = asrContextText
        self.semanticContext = semanticContext
    }
}

struct VoiceAudioChunk: Equatable, Sendable {
    let sequence: Int
    let pcmData: Data
    let duration: TimeInterval
}

struct QwenRealtimeConfiguration: Equatable, Sendable {
    let baseURL: URL
    let model: String
    let apiKey: String
    let finalizationTimeout: TimeInterval
}

enum VoiceKernelUpdate: Equatable {
    case preview(TranscriptSnapshot)
    case segmentCompleted(itemID: String, text: String)
    case fallbackActivated(reason: String)
}

enum VoiceKernelResult: Equatable {
    case realtimeFinal(text: String, rawTranscript: String, clip: RecordedAudioClip)
    case batchFallback(clip: RecordedAudioClip, reason: String)
}

enum StreamingTranscriptEvent: Equatable, Sendable {
    case sessionReady
    case speechStarted(itemID: String?)
    case delta(itemID: String, confirmedText: String, tentativeText: String)
    case completed(itemID: String, transcript: String)
    case sessionFinished
}

enum VoiceKernelFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidEndpoint(String)
    case invalidServerEvent(String)
    case provider(code: String, message: String)
    case connection(String)
    case finalizationTimeout
    case audioBackpressure
    case sessionBusy
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .invalidEndpoint(detail):
            return "实时语音服务地址无效：\(detail)"
        case let .invalidServerEvent(detail):
            return "实时语音服务返回了无法识别的数据：\(detail)"
        case let .provider(code, message):
            return "实时语音服务错误（\(code)）：\(message)"
        case let .connection(detail):
            return "实时语音连接失败：\(detail)"
        case .finalizationTimeout:
            return "实时语音服务没有及时返回最终结果。"
        case .audioBackpressure:
            return "实时音频发送速度跟不上录音速度，已切换到完整录音识别。"
        case .sessionBusy:
            return "已有语音会话正在进行。"
        case .cancelled:
            return "语音会话已取消。"
        }
    }
}

struct TranscriptSnapshot: Equatable, Sendable {
    let committedText: String
    let tentativeText: String

    var previewText: String {
        TranscriptTextComposer.join(committedText, tentativeText)
    }

    var finalText: String {
        previewText
    }
}

enum TranscriptTextComposer {
    static func join(_ left: String, _ right: String) -> String {
        let normalizedLeft = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRight = right.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedLeft.isEmpty else {
            return normalizedRight
        }
        guard !normalizedRight.isEmpty else {
            return normalizedLeft
        }

        if needsASCIIBoundarySpace(between: normalizedLeft, and: normalizedRight) {
            return "\(normalizedLeft) \(normalizedRight)"
        }
        return normalizedLeft + normalizedRight
    }

    private static func needsASCIIBoundarySpace(between left: String, and right: String) -> Bool {
        guard
            let leftScalar = left.unicodeScalars.last,
            let rightScalar = right.unicodeScalars.first
        else {
            return false
        }

        return isASCIIWordScalar(leftScalar) && isASCIIWordScalar(rightScalar)
    }

    private static func isASCIIWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }
}

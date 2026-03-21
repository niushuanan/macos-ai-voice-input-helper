import Foundation

enum SessionPhase: String, CaseIterable {
    case idle
    case listening
    case transcribing
    case rewriting
    case inserting
    case cancelled
    case error

    var title: String {
        switch self {
        case .idle:
            return "待命"
        case .listening:
            return "聆听中"
        case .transcribing:
            return "转写中"
        case .rewriting:
            return "改写中"
        case .inserting:
            return "写回中"
        case .cancelled:
            return "已取消"
        case .error:
            return "异常"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .idle:
            return "waveform.circle"
        case .listening:
            return "waveform.circle.fill"
        case .transcribing:
            return "text.bubble"
        case .rewriting:
            return "wand.and.stars"
        case .inserting:
            return "arrow.down.doc"
        case .cancelled:
            return "slash.circle"
        case .error:
            return "exclamationmark.triangle"
        }
    }
}

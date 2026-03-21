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
            return "Idle"
        case .listening:
            return "Listening"
        case .transcribing:
            return "Transcribing"
        case .rewriting:
            return "Rewriting"
        case .inserting:
            return "Inserting"
        case .cancelled:
            return "Cancelled"
        case .error:
            return "Error"
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

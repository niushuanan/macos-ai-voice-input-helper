import Foundation

enum InputLane: String {
    case directDictation
    case selectionRewrite

    var title: String {
        switch self {
        case .directDictation:
            return "Direct Dictation"
        case .selectionRewrite:
            return "Selection Rewrite"
        }
    }

    var summary: String {
        switch self {
        case .directDictation:
            return "Speak and insert fresh text into the focused app."
        case .selectionRewrite:
            return "Speak intent and reshape the selected text in place."
        }
    }
}

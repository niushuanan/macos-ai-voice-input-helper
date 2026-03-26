import Foundation

enum MagicianTransformMode: String, Codable, Equatable {
    case translate
    case polish
    case expand
    case shorten
    case fix
}

struct MagicianIntentParams: Codable, Equatable {
    var mode: MagicianTransformMode?
    var targetLanguage: String?
    var tone: String?
    var query: String?
    var title: String?
    var startAt: String?
    var endAt: String?
    var location: String?
    var noteBody: String?
    var mailTo: [String]?
    var mailSubject: String?
    var mailBody: String?

    static let empty = MagicianIntentParams()
}

struct MagicianIntent: Codable, Equatable {
    let intent: MagicianFeatureID
    let confidence: Double
    let sourceText: String
    let params: MagicianIntentParams
}

enum MagicianErrorCode: String, Equatable {
    case selectionEmpty = "selection_empty"
    case permissionDenied = "permission_denied"
    case intentParseFailed = "intent_parse_failed"
    case toolExecutionFailed = "tool_execution_failed"
    case eventCreateFailed = "event_create_failed"
    case shortcutNotFound = "shortcut_not_found"
    case mailUnavailable = "mail_unavailable"
    case browserUnavailable = "browser_unavailable"
}

struct MagicianError: Error, Equatable {
    let code: MagicianErrorCode
    let userMessage: String
    let debugMessage: String?
    let recoverAction: String?
}

struct MagicianExecutionResult: Equatable {
    let intent: MagicianFeatureID
    let userMessage: String
    let outputText: String?
    let historyDisplayText: String?
    let fallbackUsed: Bool

    init(
        intent: MagicianFeatureID,
        userMessage: String,
        outputText: String?,
        historyDisplayText: String? = nil,
        fallbackUsed: Bool
    ) {
        self.intent = intent
        self.userMessage = userMessage
        self.outputText = outputText
        self.historyDisplayText = historyDisplayText
        self.fallbackUsed = fallbackUsed
    }
}

struct MagicianExecutionContext: Equatable {
    let command: String
    let selection: FocusedSelectionSnapshot?
    let focusContext: FocusedAppContext

    var selectedText: String {
        selection?.selectedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

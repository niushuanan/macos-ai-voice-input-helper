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
    var title: String?
    var startAt: String?
    var endAt: String?
    var location: String?
    var notes: String?
    var noteBody: String?
    var mailTo: [String]?
    var mailRecipientHints: [String]?
    var mailDeliveryMode: MagicianMailDeliveryMode?
    var mailSubject: String?
    var mailBody: String?

    init(
        mode: MagicianTransformMode? = nil,
        targetLanguage: String? = nil,
        tone: String? = nil,
        title: String? = nil,
        startAt: String? = nil,
        endAt: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        noteBody: String? = nil,
        mailTo: [String]? = nil,
        mailRecipientHints: [String]? = nil,
        mailDeliveryMode: MagicianMailDeliveryMode? = nil,
        mailSubject: String? = nil,
        mailBody: String? = nil
    ) {
        self.mode = mode
        self.targetLanguage = targetLanguage
        self.tone = tone
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.location = location
        self.notes = notes
        self.noteBody = noteBody
        self.mailTo = mailTo
        self.mailRecipientHints = mailRecipientHints
        self.mailDeliveryMode = mailDeliveryMode
        self.mailSubject = mailSubject
        self.mailBody = mailBody
    }

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
    case mailAutomationDenied = "mail_automation_denied"
    case mailAppleScriptFailed = "mail_applescript_failed"
    case mailRecipientUnresolved = "mail_recipient_unresolved"
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

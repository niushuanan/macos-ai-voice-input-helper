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
    var cliOperation: String?
    var cliArguments: [String]?

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
        mailBody: String? = nil,
        cliOperation: String? = nil,
        cliArguments: [String]? = nil
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
        self.cliOperation = cliOperation
        self.cliArguments = cliArguments
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
    case cliUnavailable = "cli_unavailable"
    case cliAuthRequired = "cli_auth_required"
    case cliCommandRejected = "cli_command_rejected"
    case cliExecutionTimedOut = "cli_execution_timed_out"
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
    let observation: MagicianAgentObservation?

    init(
        intent: MagicianFeatureID,
        userMessage: String,
        outputText: String?,
        historyDisplayText: String? = nil,
        fallbackUsed: Bool,
        observation: MagicianAgentObservation? = nil
    ) {
        self.intent = intent
        self.userMessage = userMessage
        self.outputText = outputText
        self.historyDisplayText = historyDisplayText
        self.fallbackUsed = fallbackUsed
        self.observation = observation
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

enum MagicianWorkflowInputBinding: String, Codable, Equatable {
    case selectionText = "selection_text"
    case previousOutput = "previous_output"
    case commandOnly = "command_only"
}

struct MagicianWorkflowStepRetryPolicy: Codable, Equatable {
    let maxAttempts: Int
    let backoffMilliseconds: [Int]

    init(
        maxAttempts: Int = 2,
        backoffMilliseconds: [Int] = [200, 600]
    ) {
        self.maxAttempts = max(1, min(maxAttempts, 3))
        self.backoffMilliseconds = backoffMilliseconds
            .map { max(0, $0) }
            .prefix(3)
            .map { $0 }
    }

    static let `default` = MagicianWorkflowStepRetryPolicy()
}

struct MagicianWorkflowStep: Codable, Equatable, Identifiable {
    let stepID: String
    let feature: MagicianFeatureID
    let params: MagicianIntentParams
    let inputBinding: MagicianWorkflowInputBinding
    let retryPolicy: MagicianWorkflowStepRetryPolicy?
    let timeoutMs: Int?
    let command: String?

    var id: String { stepID }

    init(
        stepID: String,
        feature: MagicianFeatureID,
        params: MagicianIntentParams = .empty,
        inputBinding: MagicianWorkflowInputBinding = .selectionText,
        retryPolicy: MagicianWorkflowStepRetryPolicy? = nil,
        timeoutMs: Int? = nil,
        command: String? = nil
    ) {
        self.stepID = stepID
        self.feature = feature
        self.params = params
        self.inputBinding = inputBinding
        self.retryPolicy = retryPolicy
        self.timeoutMs = timeoutMs
        self.command = command
    }
}

struct MagicianWorkflowPlan: Codable, Equatable {
    let version: Int
    let steps: [MagicianWorkflowStep]
    let rationale: String?
    let confidence: Double

    init(
        version: Int = 1,
        steps: [MagicianWorkflowStep],
        rationale: String? = nil,
        confidence: Double = 0.8
    ) {
        self.version = version
        self.steps = steps
        self.rationale = rationale
        self.confidence = confidence
    }
}

struct MagicianWorkflowStepResult: Equatable {
    let step: MagicianWorkflowStep
    let userMessage: String
    let outputText: String?
    let historyDisplayText: String?
    let fallbackUsed: Bool
    let observation: MagicianAgentObservation?

    init(
        step: MagicianWorkflowStep,
        userMessage: String,
        outputText: String?,
        historyDisplayText: String?,
        fallbackUsed: Bool,
        observation: MagicianAgentObservation? = nil
    ) {
        self.step = step
        self.userMessage = userMessage
        self.outputText = outputText
        self.historyDisplayText = historyDisplayText
        self.fallbackUsed = fallbackUsed
        self.observation = observation
    }
}

struct MagicianWorkflowExecutionResult: Equatable {
    let stepResults: [MagicianWorkflowStepResult]
    let finalStatusMessage: String
    let finalOutputText: String?
}

struct MagicianWorkflowExecutionContext: Equatable {
    let command: String
    let selection: FocusedSelectionSnapshot?
    let focusContext: FocusedAppContext
    let traceID: String

    var selectedText: String {
        selection?.selectedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

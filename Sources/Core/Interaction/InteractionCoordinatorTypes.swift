import Foundation

struct WakeInvocationContext: Equatable {
    enum Source: String, Equatable {
        case dictationTap
        case magicianHold
    }

    let source: Source

    static let dictationTap = WakeInvocationContext(source: .dictationTap)
    static let magicianHold = WakeInvocationContext(source: .magicianHold)
    static let dictation = WakeInvocationContext.dictationTap
}

struct DictationWritebackTarget: Equatable {
    let focusContext: FocusedAppContext
    let processIdentifier: pid_t?

    var snapshot: WritebackTargetSnapshot {
        WritebackTargetSnapshot(
            appName: focusContext.appName,
            bundleID: focusContext.bundleID,
            processIdentifier: processIdentifier
        )
    }
}

struct DictationTextProcessingPolicy {
    static let shortCleanLengthThreshold = 10

    static func shouldUseModel(text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return false
        }

        if normalized.contains("<|") || normalized.contains("|>") {
            return true
        }

        if normalized.contains("  ") || hasRepeatedPunctuation(in: normalized) {
            return true
        }

        if normalized.split(whereSeparator: \.isNewline).count > 1 {
            return true
        }

        return normalized.count > shortCleanLengthThreshold
    }

    private static func hasRepeatedPunctuation(in text: String) -> Bool {
        let repeatedTokens = ["。。", "，，", "！！", "？？", "..", ",,", "!!", "??"]
        return repeatedTokens.contains { text.contains($0) }
    }
}

struct ASRTranscriptionOutcome {
    let result: SpeechTranscriptionResult
    let attempts: Int
}

struct ASRTranscriptionFailure: Error {
    let error: SpeechTranscriptionError
    let attempts: Int
}

enum DictationRoute {
    case asrOnly
    case asrAndTextProcessing
}

struct DictationPostProcessOutcome {
    let route: DictationRoute
    let text: String
    let appliedSkills: [SkillRuleID]
    let nonBlockingNotice: String?
}

struct BrainstormComposeOutcome {
    let summaryText: String
    let dialogueText: String
    let rewriteProvider: String?
    let rewriteModel: String?
    let tokenBudget: Int?
    let appliedSkills: [SkillRuleID]
    let nonBlockingNotice: String?
}

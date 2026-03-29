import Foundation

enum MagicianAgentVerificationStatus: String, Codable, Equatable {
    case verified
    case assumed
    case needsUserInput = "needs_user_input"
    case unverified

    var displayText: String {
        switch self {
        case .verified:
            return "已核验"
        case .assumed:
            return "已执行"
        case .needsUserInput:
            return "待补信息"
        case .unverified:
            return "未核验"
        }
    }
}

struct MagicianAgentObservation: Codable, Equatable {
    let verificationStatus: MagicianAgentVerificationStatus
    let targetSummary: String?
    let evidenceSummary: String?
    let autoRepairApplied: Bool

    init(
        verificationStatus: MagicianAgentVerificationStatus,
        targetSummary: String? = nil,
        evidenceSummary: String? = nil,
        autoRepairApplied: Bool = false
    ) {
        self.verificationStatus = verificationStatus
        self.targetSummary = targetSummary
        self.evidenceSummary = evidenceSummary
        self.autoRepairApplied = autoRepairApplied
    }
}

struct MagicianTargetResolution: Codable, Equatable {
    enum Status: String, Codable, Equatable {
        case resolved
        case ambiguous
        case missing
    }

    let status: Status
    let targetType: String?
    let targetID: String?
    let targetName: String?
    let prompt: String?
    let alternatives: [String]

    init(
        status: Status,
        targetType: String? = nil,
        targetID: String? = nil,
        targetName: String? = nil,
        prompt: String? = nil,
        alternatives: [String] = []
    ) {
        self.status = status
        self.targetType = targetType
        self.targetID = targetID
        self.targetName = targetName
        self.prompt = prompt
        self.alternatives = alternatives
    }
}

struct MagicianAgentStep: Codable, Equatable, Identifiable {
    let id: String
    let workflowStep: MagicianWorkflowStep

    init(id: String, workflowStep: MagicianWorkflowStep) {
        self.id = id
        self.workflowStep = workflowStep
    }
}

struct MagicianAgentPlan: Codable, Equatable {
    let version: Int
    let steps: [MagicianAgentStep]
    let maxAutoReplans: Int
    let maxAutoRetries: Int
    let rationale: String?
    let confidence: Double

    init(
        version: Int = 1,
        steps: [MagicianAgentStep],
        maxAutoReplans: Int = 1,
        maxAutoRetries: Int = 1,
        rationale: String? = nil,
        confidence: Double = 0.8
    ) {
        self.version = version
        self.steps = steps
        self.maxAutoReplans = max(0, min(maxAutoReplans, 1))
        self.maxAutoRetries = max(0, min(maxAutoRetries, 1))
        self.rationale = rationale
        self.confidence = confidence
    }

    init(workflowPlan: MagicianWorkflowPlan, maxAutoReplans: Int = 1, maxAutoRetries: Int = 1) {
        self.init(
            version: workflowPlan.version,
            steps: workflowPlan.steps.map { MagicianAgentStep(id: $0.stepID, workflowStep: $0) },
            maxAutoReplans: maxAutoReplans,
            maxAutoRetries: maxAutoRetries,
            rationale: workflowPlan.rationale,
            confidence: workflowPlan.confidence
        )
    }
}

struct MagicianAgentExecutionResult: Equatable {
    let executionResult: MagicianExecutionResult
    let observation: MagicianAgentObservation?
    let targetResolution: MagicianTargetResolution?
    let replanned: Bool

    init(
        executionResult: MagicianExecutionResult,
        observation: MagicianAgentObservation? = nil,
        targetResolution: MagicianTargetResolution? = nil,
        replanned: Bool = false
    ) {
        self.executionResult = executionResult
        self.observation = observation
        self.targetResolution = targetResolution
        self.replanned = replanned
    }
}

protocol MagicianTargetResolver {
    func resolveTarget(
        command: String,
        selection: String?,
        focusContext: FocusedAppContext?
    ) async -> MagicianTargetResolution
}

protocol MagicianResultVerifier {
    func verify(
        executionResult: MagicianExecutionResult,
        context: MagicianExecutionContext
    ) async -> MagicianAgentObservation
}

protocol MagicianReplanPolicy {
    func shouldAutoReplan(
        after error: MagicianError,
        step: MagicianWorkflowStep,
        attempt: Int
    ) -> Bool
}

struct DefaultMagicianReplanPolicy: MagicianReplanPolicy {
    func shouldAutoReplan(
        after error: MagicianError,
        step: MagicianWorkflowStep,
        attempt: Int
    ) -> Bool {
        guard attempt <= 1 else {
            return false
        }
        guard step.feature == .feishuCLI else {
            return false
        }
        switch error.code {
        case .intentParseFailed, .cliAuthRequired, .toolExecutionFailed:
            return true
        default:
            return false
        }
    }
}

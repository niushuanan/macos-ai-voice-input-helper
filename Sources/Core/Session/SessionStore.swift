import Combine
import Foundation

enum SessionHUDProgressHint {
    static let idle = 0.0
    static let transcribing = 0.18
    static let workflowPreview = 0.46
    static let textTransform = 0.62
    static let inserting = 0.90
    static let done = 1.0

    static func workflowStep(index: Int, totalSteps: Int) -> Double {
        let safeTotal = max(1, totalSteps)
        let safeIndex = min(max(1, index), safeTotal)
        let hint = workflowPreview + (Double(safeIndex) / Double(safeTotal + 1)) * 0.32
        return min(0.78, hint)
    }
}

@MainActor
final class SessionStore: ObservableObject {
    enum RewriteStageKind {
        case textTransform
        case toolAction
    }

    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var activeLane: InputLane = .directDictation
    @Published private(set) var statusMessage: String = "已准备，可通过快捷键开始语音会话。"
    @Published private(set) var hudProgressHint: Double = SessionHUDProgressHint.idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var listeningLevel: Double = 0
    @Published private(set) var pendingClip: RecordedAudioClip?
    @Published private(set) var latestTranscription: SpeechTranscriptionResult?
    @Published private(set) var latestFocusContext: FocusedAppContext?
    @Published private(set) var latestOutputResult: TextOutputResult?
    @Published private(set) var liveOutputPreview: String?

    private let allowedTransitions: [SessionPhase: Set<SessionPhase>] = [
        .idle: [.listening],
        .listening: [.transcribing, .cancelled, .error],
        .transcribing: [.idle, .rewriting, .inserting, .cancelled, .error],
        .rewriting: [.idle, .inserting, .cancelled, .error],
        .inserting: [.idle, .cancelled, .error],
        .cancelled: [.idle, .listening],
        .error: [.idle, .listening]
    ]

    func startDictation() {
        clearRuntimeArtifactsForNewSession()
        activeLane = .directDictation
        transition(
            to: .listening,
            statusMessage: "正在聆听普通听写。",
            hudProgressHint: SessionHUDProgressHint.idle
        )
    }

    func startRewrite() {
        clearRuntimeArtifactsForNewSession()
        activeLane = .selectionRewrite
        transition(
            to: .listening,
            statusMessage: "正在聆听魔术先生指令。",
            hudProgressHint: SessionHUDProgressHint.idle
        )
    }

    func startBrainstorm() {
        clearRuntimeArtifactsForNewSession()
        activeLane = .brainstormDiscussion
        transition(
            to: .listening,
            statusMessage: "正在记录一口气全念对内容。",
            hudProgressHint: SessionHUDProgressHint.idle
        )
    }

    func markTranscribing(audioSummary: String? = nil) {
        if let audioSummary {
            transition(
                to: .transcribing,
                statusMessage: "录音已完成：\(audioSummary)",
                hudProgressHint: SessionHUDProgressHint.transcribing
            )
        } else {
            transition(
                to: .transcribing,
                statusMessage: "正在把语音转成文本请求。",
                hudProgressHint: SessionHUDProgressHint.transcribing
            )
        }
    }

    func markTranscribing(
        audioSummary: String,
        providerName: String,
        modelName: String
    ) {
        transition(
            to: .transcribing,
            statusMessage: "正在用 \(providerName) · \(modelName) 转写（\(audioSummary)）。",
            hudProgressHint: SessionHUDProgressHint.transcribing
        )
    }

    func completeTranscription(result: SpeechTranscriptionResult) {
        latestTranscription = result
    }

    func markDictationPostProcessing(
        providerName: String,
        modelName: String
    ) {
        activeLane = .directDictation
        liveOutputPreview = nil
        transition(
            to: .rewriting,
            statusMessage: "正在用 \(providerName) · \(modelName) 整理听写。",
            hudProgressHint: SessionHUDProgressHint.textTransform
        )
    }

    func updateDictationPostProcessingPreview(_ previewText: String) {
        let normalized = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }

        liveOutputPreview = normalized
        transition(
            to: .rewriting,
            statusMessage: "听写整理中：\(normalized)",
            hudProgressHint: livePreviewProgressHint(for: normalized)
        )
    }

    func markInserting(
        transcription result: SpeechTranscriptionResult,
        focusContext: FocusedAppContext
    ) {
        latestTranscription = result
        latestFocusContext = focusContext
        transition(
            to: .inserting,
            statusMessage: "正在把文本写入 \(focusContext.appName)。",
            hudProgressHint: SessionHUDProgressHint.inserting
        )
    }

    func completeInsertion(
        outputResult: TextOutputResult,
        note: String? = nil
    ) {
        latestOutputResult = outputResult
        pendingClip = nil
        listeningLevel = 0
        liveOutputPreview = nil
        let statusMessage: String
        switch outputResult.path {
        case .accessibilitySelectionReplacement:
            statusMessage = "文本已写入 \(outputResult.appName)（AX 直写路径）。"
        case .pasteFallbackCommandV:
            statusMessage = "文本已写入 \(outputResult.appName)（粘贴兜底路径）。"
        case .clipboardOnly:
            statusMessage = "当前没有可直接写入的输入框，文本已复制到剪贴板。"
        }

        if let note, !note.isEmpty {
            transition(
                to: .idle,
                statusMessage: "\(statusMessage) \(note)",
                hudProgressHint: SessionHUDProgressHint.done
            )
        } else {
            transition(
                to: .idle,
                statusMessage: statusMessage,
                hudProgressHint: SessionHUDProgressHint.done
            )
        }
    }

    func markRewriting(
        actionLabel: String? = nil,
        stage: RewriteStageKind = .textTransform,
        progressHint: Double? = nil
    ) {
        activeLane = .selectionRewrite
        let normalizedLabel = actionLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch stage {
        case .textTransform:
            let resolvedHint = progressHint ?? SessionHUDProgressHint.textTransform
            if normalizedLabel.isEmpty {
                transition(
                    to: .rewriting,
                    statusMessage: "魔术先生文字处理中。",
                    hudProgressHint: resolvedHint
                )
            } else {
                transition(
                    to: .rewriting,
                    statusMessage: "魔术先生文字处理中：\(normalizedLabel)。",
                    hudProgressHint: resolvedHint
                )
            }
        case .toolAction:
            let resolvedHint = progressHint ?? SessionHUDProgressHint.workflowPreview
            if normalizedLabel.isEmpty {
                transition(
                    to: .rewriting,
                    statusMessage: "魔术先生执行中。",
                    hudProgressHint: resolvedHint
                )
            } else {
                transition(
                    to: .rewriting,
                    statusMessage: "魔术先生执行中：\(normalizedLabel)。",
                    hudProgressHint: resolvedHint
                )
            }
        }
    }

    func markInserting() {
        transition(
            to: .inserting,
            statusMessage: "正在把最终文本写回当前应用。",
            hudProgressHint: SessionHUDProgressHint.inserting
        )
    }

    func completeInsertion() {
        pendingClip = nil
        listeningLevel = 0
        liveOutputPreview = nil
        transition(
            to: .idle,
            statusMessage: "已完成，可开始下一次语音会话。",
            hudProgressHint: SessionHUDProgressHint.done
        )
    }

    func completeAction(statusMessage: String) {
        pendingClip = nil
        listeningLevel = 0
        liveOutputPreview = nil
        transition(
            to: .idle,
            statusMessage: statusMessage,
            hudProgressHint: SessionHUDProgressHint.done
        )
    }

    func cancel() {
        clearRuntimeArtifactsForNewSession()
        phase = .cancelled
        statusMessage = "本次会话已取消，目标应用内容未变化。"
        hudProgressHint = SessionHUDProgressHint.idle
    }

    func fail(message: String) {
        listeningLevel = 0
        pendingClip = nil
        latestOutputResult = nil
        liveOutputPreview = nil
        errorMessage = message
        phase = .error
        statusMessage = message
        hudProgressHint = SessionHUDProgressHint.idle
    }

    func reset() {
        clearRuntimeArtifactsForNewSession()
        activeLane = .directDictation
        phase = .idle
        statusMessage = "已准备，可通过快捷键开始语音会话。"
        hudProgressHint = SessionHUDProgressHint.idle
    }

    func updateListeningLevel(_ level: Double) {
        let clamped = max(0, min(1, level))
        listeningLevel = clamped
    }

    func updateRealtimeTranscriptionPreview(_ previewText: String) {
        guard phase == .listening else {
            return
        }
        let normalized = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }
        liveOutputPreview = normalized
        statusMessage = "正在边听边转写：\(normalized)"
    }

    func noteRealtimeFallback() {
        guard phase == .listening else {
            return
        }
        statusMessage = "实时转写暂不可用，结束录音后会自动用完整录音识别。"
    }

    func attachPendingClip(_ clip: RecordedAudioClip) {
        pendingClip = clip
    }

    func clearPendingClipReference() {
        pendingClip = nil
    }

    private func clearRuntimeArtifactsForNewSession() {
        pendingClip = nil
        listeningLevel = 0
        errorMessage = nil
        latestTranscription = nil
        latestFocusContext = nil
        latestOutputResult = nil
        liveOutputPreview = nil
    }

    private func transition(
        to nextPhase: SessionPhase,
        statusMessage: String,
        hudProgressHint: Double
    ) {
        guard phase == nextPhase || allowedTransitions[phase, default: []].contains(nextPhase) else {
            return
        }

        errorMessage = nil
        phase = nextPhase
        self.statusMessage = statusMessage
        self.hudProgressHint = max(0, min(1, hudProgressHint))
    }

    private func livePreviewProgressHint(for previewText: String) -> Double {
        let normalizedCount = min(previewText.count, 220)
        let ratio = Double(normalizedCount) / 220.0
        return min(0.82, SessionHUDProgressHint.textTransform + (ratio * 0.16))
    }
}

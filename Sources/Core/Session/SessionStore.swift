import Combine
import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var activeLane: InputLane = .directDictation
    @Published private(set) var statusMessage: String = "已准备，可通过快捷键开始语音会话。"
    @Published private(set) var errorMessage: String?
    @Published private(set) var listeningLevel: Double = 0
    @Published private(set) var pendingClip: RecordedAudioClip?
    @Published private(set) var latestTranscription: SpeechTranscriptionResult?
    @Published private(set) var latestFocusContext: FocusedAppContext?
    @Published private(set) var latestOutputResult: TextOutputResult?

    private let allowedTransitions: [SessionPhase: Set<SessionPhase>] = [
        .idle: [.listening],
        .listening: [.transcribing, .cancelled, .error],
        .transcribing: [.idle, .rewriting, .inserting, .cancelled, .error],
        .rewriting: [.inserting, .cancelled, .error],
        .inserting: [.idle, .cancelled, .error],
        .cancelled: [.idle, .listening],
        .error: [.idle, .listening]
    ]

    func startDictation() {
        clearRuntimeArtifactsForNewSession()
        activeLane = .directDictation
        transition(to: .listening, statusMessage: "正在聆听普通听写。")
    }

    func startRewrite() {
        clearRuntimeArtifactsForNewSession()
        activeLane = .selectionRewrite
        transition(to: .listening, statusMessage: "正在聆听选区改写指令。")
    }

    func markTranscribing(audioSummary: String? = nil) {
        if let audioSummary {
            transition(to: .transcribing, statusMessage: "录音已完成：\(audioSummary)")
        } else {
            transition(to: .transcribing, statusMessage: "正在把语音转成文本请求。")
        }
    }

    func markTranscribing(
        audioSummary: String,
        providerName: String,
        modelName: String
    ) {
        transition(
            to: .transcribing,
            statusMessage: "正在用 \(providerName) · \(modelName) 转写（\(audioSummary)）。"
        )
    }

    func completeTranscription(result: SpeechTranscriptionResult) {
        latestTranscription = result
    }

    func markInserting(
        transcription result: SpeechTranscriptionResult,
        focusContext: FocusedAppContext
    ) {
        latestTranscription = result
        latestFocusContext = focusContext
        transition(
            to: .inserting,
            statusMessage: "正在把文本写入 \(focusContext.appName)。"
        )
    }

    func completeInsertion(outputResult: TextOutputResult) {
        latestOutputResult = outputResult
        pendingClip = nil
        listeningLevel = 0
        let pathTitle = outputResult.usedFallback ? "粘贴兜底路径" : "AX 直写路径"
        transition(to: .idle, statusMessage: "文本已写入 \(outputResult.appName)（\(pathTitle)）。")
    }

    func markRewriting(actionLabel: String? = nil) {
        activeLane = .selectionRewrite
        if let actionLabel, !actionLabel.isEmpty {
            transition(
                to: .rewriting,
                statusMessage: "正在对选中文本执行：\(actionLabel)。"
            )
        } else {
            transition(
                to: .rewriting,
                statusMessage: "正在按语音指令改写选中文本。"
            )
        }
    }

    func markInserting() {
        transition(to: .inserting, statusMessage: "正在把最终文本写回当前应用。")
    }

    func completeInsertion() {
        pendingClip = nil
        listeningLevel = 0
        transition(to: .idle, statusMessage: "已完成，可开始下一次语音会话。")
    }

    func cancel() {
        clearRuntimeArtifactsForNewSession()
        phase = .cancelled
        statusMessage = "本次会话已取消，目标应用内容未变化。"
    }

    func fail(message: String) {
        listeningLevel = 0
        pendingClip = nil
        latestOutputResult = nil
        errorMessage = message
        phase = .error
        statusMessage = message
    }

    func reset() {
        clearRuntimeArtifactsForNewSession()
        activeLane = .directDictation
        phase = .idle
        statusMessage = "已准备，可通过快捷键开始语音会话。"
    }

    func updateListeningLevel(_ level: Double) {
        let clamped = max(0, min(1, level))
        listeningLevel = clamped
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
    }

    private func transition(to nextPhase: SessionPhase, statusMessage: String) {
        guard phase == nextPhase || allowedTransitions[phase, default: []].contains(nextPhase) else {
            return
        }

        errorMessage = nil
        phase = nextPhase
        self.statusMessage = statusMessage
    }
}

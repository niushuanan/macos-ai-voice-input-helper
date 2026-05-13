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
    let finalWritebackText: String
    let priorStreamingWriteResult: TextOutputResult?
    let appliedSkills: [SkillRuleID]
    let nonBlockingNotice: String?
}

struct DictationStreamingWritebackFinalization {
    let finalWritebackText: String
    let priorStreamingWriteResult: TextOutputResult?
    let note: String?
    let shouldPersistFinalTextToClipboard: Bool
}

struct DictationStreamingWritebackPolicy {
    static func supportsExternalStreaming(
        focusContext: FocusedAppContext,
        preferredTarget: WritebackTargetSnapshot?
    ) -> Bool {
        let bundleID = preferredTarget?.bundleID ?? focusContext.bundleID
        guard
            !bundleID.isEmpty,
            bundleID != "unknown.bundle",
            bundleID != Bundle.main.bundleIdentifier
        else {
            return false
        }

        if blockedBundleIDs.contains(bundleID) {
            return false
        }

        let lowercasedBundleID = bundleID.lowercased()
        let blockedFragments = [
            "com.openai.codex",
            "slack",
            "discord",
            "code",
            "cursor"
        ]
        return !blockedFragments.contains { lowercasedBundleID.contains($0) }
    }

    private static let blockedBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.rdc.macos",
        "com.citrix.receiver.icaviewer.mac",
        "com.teamviewer.TeamViewer",
        "com.parallels.desktop.console"
    ]
}

struct StableStreamingPrefixAccumulator {
    private(set) var committedPrefix: String = ""
    private var previousPreview: String?

    private let minimumBoundaryChunkLength = 3
    private let forcedCommitThreshold = 22
    private let forcedCommitTailReserve = 6
    private let boundaryCharacters = CharacterSet(charactersIn: "，。！？；：、,.!?;: \n")

    mutating func ingest(_ previewText: String) -> String? {
        let normalized = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }

        defer {
            previousPreview = normalized
        }

        guard let previousPreview, !previousPreview.isEmpty else {
            return nil
        }

        let stablePrefix = longestCommonPrefix(previousPreview, normalized)
        return commitDelta(fromStablePrefix: stablePrefix)
    }

    mutating func finalize(with finalText: String) -> DictationStreamingWritebackFinalization {
        let normalizedFinal = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committedPrefix.isEmpty else {
            return DictationStreamingWritebackFinalization(
                finalWritebackText: normalizedFinal,
                priorStreamingWriteResult: nil,
                note: nil,
                shouldPersistFinalTextToClipboard: false
            )
        }

        if normalizedFinal.hasPrefix(committedPrefix) {
            let suffix = String(normalizedFinal.dropFirst(committedPrefix.count))
            return DictationStreamingWritebackFinalization(
                finalWritebackText: suffix,
                priorStreamingWriteResult: nil,
                note: nil,
                shouldPersistFinalTextToClipboard: false
            )
        }

        return DictationStreamingWritebackFinalization(
            finalWritebackText: "",
            priorStreamingWriteResult: nil,
            note: "流式阶段已写入前半段，最终全文已放入剪贴板，请以完整结果为准。",
            shouldPersistFinalTextToClipboard: true
        )
    }

    private mutating func commitDelta(fromStablePrefix stablePrefix: String) -> String? {
        guard stablePrefix.count > committedPrefix.count else {
            return nil
        }

        let committedCount = committedPrefix.count
        let commitEndIndex = preferredCommitEnd(in: stablePrefix, committedCount: committedCount)
        let committedIndex = stablePrefix.index(
            stablePrefix.startIndex,
            offsetBy: committedCount,
            limitedBy: stablePrefix.endIndex
        ) ?? stablePrefix.startIndex
        guard commitEndIndex > committedIndex else {
            return nil
        }

        let delta = String(stablePrefix[committedIndex..<commitEndIndex])
        committedPrefix = String(stablePrefix[..<commitEndIndex])
        return delta
    }

    private func preferredCommitEnd(in stablePrefix: String, committedCount: Int) -> String.Index {
        let startIndex = stablePrefix.index(
            stablePrefix.startIndex,
            offsetBy: committedCount,
            limitedBy: stablePrefix.endIndex
        ) ?? stablePrefix.startIndex
        guard startIndex < stablePrefix.endIndex else {
            return startIndex
        }

        var currentIndex = startIndex
        var boundaryIndex: String.Index?
        var advancedCount = 0
        while currentIndex < stablePrefix.endIndex {
            let nextIndex = stablePrefix.index(after: currentIndex)
            advancedCount += 1
            let scalarView = String(stablePrefix[currentIndex]).unicodeScalars
            if scalarView.allSatisfy(boundaryCharacters.contains), advancedCount >= minimumBoundaryChunkLength {
                boundaryIndex = nextIndex
            }
            currentIndex = nextIndex
        }

        if let boundaryIndex {
            return boundaryIndex
        }

        guard advancedCount >= forcedCommitThreshold else {
            return startIndex
        }

        let committedCount = max(minimumBoundaryChunkLength, advancedCount - forcedCommitTailReserve)
        return stablePrefix.index(startIndex, offsetBy: committedCount, limitedBy: stablePrefix.endIndex) ?? startIndex
    }

    private func longestCommonPrefix(_ lhs: String, _ rhs: String) -> String {
        var leftIndex = lhs.startIndex
        var rightIndex = rhs.startIndex
        var prefixEnd = lhs.startIndex

        while leftIndex < lhs.endIndex, rightIndex < rhs.endIndex, lhs[leftIndex] == rhs[rightIndex] {
            prefixEnd = lhs.index(after: leftIndex)
            leftIndex = lhs.index(after: leftIndex)
            rightIndex = rhs.index(after: rightIndex)
        }

        return String(lhs[..<prefixEnd])
    }
}

@MainActor
final class DictationStreamingWritebackController {
    private let textOutputCoordinator: any TextOutputCoordinator
    private let focusContext: FocusedAppContext
    private let preferredTarget: WritebackTargetSnapshot?
    private let isEnabled: Bool

    private var accumulator = StableStreamingPrefixAccumulator()
    private(set) var lastOutputResult: TextOutputResult?
    private(set) var didWriteAnyChunk = false
    private(set) var chunkWriteFailed = false

    init(
        textOutputCoordinator: any TextOutputCoordinator,
        focusContext: FocusedAppContext,
        preferredTarget: WritebackTargetSnapshot?
    ) {
        self.textOutputCoordinator = textOutputCoordinator
        self.focusContext = focusContext
        self.preferredTarget = preferredTarget
        isEnabled = DictationStreamingWritebackPolicy.supportsExternalStreaming(
            focusContext: focusContext,
            preferredTarget: preferredTarget
        )
    }

    func handlePartial(_ previewText: String) async {
        guard isEnabled, !chunkWriteFailed else {
            return
        }
        guard let delta = accumulator.ingest(previewText) else {
            return
        }

        do {
            let result = try await textOutputCoordinator.write(
                request: TextOutputRequest(
                    text: delta,
                    operation: .insertText,
                    focusContext: focusContext,
                    preferredTarget: preferredTarget,
                    writeMode: .streamingChunk
                )
            )
            didWriteAnyChunk = true
            lastOutputResult = result
        } catch {
            chunkWriteFailed = true
        }
    }

    func finalize(with finalText: String) -> DictationStreamingWritebackFinalization {
        var result = accumulator.finalize(with: finalText)
        result = DictationStreamingWritebackFinalization(
            finalWritebackText: didWriteAnyChunk ? result.finalWritebackText : finalText,
            priorStreamingWriteResult: didWriteAnyChunk ? lastOutputResult : nil,
            note: result.note,
            shouldPersistFinalTextToClipboard: didWriteAnyChunk && result.shouldPersistFinalTextToClipboard
        )

        if chunkWriteFailed, result.note == nil {
            return DictationStreamingWritebackFinalization(
                finalWritebackText: result.finalWritebackText,
                priorStreamingWriteResult: result.priorStreamingWriteResult,
                note: "流式写入中途已退回普通写回，末尾内容会继续补全。",
                shouldPersistFinalTextToClipboard: result.shouldPersistFinalTextToClipboard
            )
        }

        return result
    }
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

struct MusicFastRequest {
    let traceID: String
    let command: String
    let intent: MagicianNormalizedIntent
    let query: String?
    let focusContext: FocusedAppContext
}

struct MusicFastOutcome {
    let status: SessionHistoryStatus
    let message: String
    let outputText: String?
    let evidenceSummary: String
    let failureCode: V4FailureCode?
}

struct MusicExecutionInterpretationRequest {
    let command: String
    let status: SessionHistoryStatus
    let outputText: String?
    let evidenceSummary: String
    let rawExecutionTrace: String
}

@MainActor
protocol MusicFastExecuting {
    func execute(_ request: MusicFastRequest) async -> MusicFastOutcome
}

@MainActor
protocol MusicExecutionInterpreting {
    func interpret(_ request: MusicExecutionInterpretationRequest) async -> String?
}

@MainActor
final class MusicExecutionInterpreter: MusicExecutionInterpreting {
    private let modelSlotManager: V4ModelSlotManager?
    private let generationProvider: any TextGenerationProvider

    init(
        providerSettingsStore: ProviderSettingsStore? = nil,
        generationProvider: (any TextGenerationProvider)? = nil
    ) {
        if let providerSettingsStore {
            let bridge = V4ProviderSettingsBridge(providerSettingsStore: providerSettingsStore)
            self.modelSlotManager = V4ModelSlotManager(bridge: bridge)
        } else {
            self.modelSlotManager = nil
        }
        self.generationProvider = generationProvider ?? OpenAITextGenerationProvider()
    }

    func interpret(_ request: MusicExecutionInterpretationRequest) async -> String? {
        guard
            let configuration = await semanticModelConfiguration(),
            let apiKey = await semanticModelAPIKey(),
            !configuration.providerType.requiresAPIKey || !apiKey.isEmpty
        else {
            return fallbackInterpretation(request)
        }

        let systemPrompt = """
        你是 PulseType 的执行解读助手。你的任务是把音乐执行结果讲清楚，给用户看懂。
        要求：
        1) 用简洁中文，分 3 段：做了什么、最终结果、下一步建议。
        2) 不要编造，必须严格依据给定原始链路。
        3) 长度控制在 120~180 字。
        """
        let userPrompt = """
        用户命令：\(request.command)
        执行状态：\(request.status.rawValue)
        输出文本：\(request.outputText ?? "(none)")
        证据：\(request.evidenceSummary)

        原始执行链路：
        \(request.rawExecutionTrace)
        """

        do {
            let generation = try await generationProvider.generateText(
                request: TextGenerationRequest(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    temperature: 0.2,
                    maxOutputTokens: 240
                ),
                configuration: configuration,
                apiKey: apiKey
            )
            let text = generation.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? fallbackInterpretation(request) : text
        } catch {
            return fallbackInterpretation(request)
        }
    }

    private func semanticModelConfiguration() async -> TextGenerationProviderConfiguration? {
        guard let modelSlotManager else {
            return nil
        }
        do {
            let endpoint = try await modelSlotManager.resolve(.agent)
            guard let baseURL = URL(string: endpoint.baseURLString) else {
                return nil
            }
            return TextGenerationProviderConfiguration(
                profileID: endpoint.credentialRef?.rawValue ?? endpoint.sourceConfigurationKey,
                providerType: endpoint.providerType,
                providerName: endpoint.providerDisplayName,
                modelName: endpoint.modelName,
                baseURL: baseURL
            )
        } catch {
            return nil
        }
    }

    private func semanticModelAPIKey() async -> String? {
        guard let modelSlotManager else {
            return nil
        }
        do {
            return try await modelSlotManager.loadAPIKey(for: .agent)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func fallbackInterpretation(_ request: MusicExecutionInterpretationRequest) -> String {
        let finalResult: String = {
            if request.status == .success {
                return request.outputText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? request.outputText!
                    : "音乐动作已完成。"
            }
            return request.outputText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? request.outputText!
                : "这次没有成功完成播放。"
        }()
        return """
        做了什么：系统按音乐快速链路解析了你的指令，并调用本机 Music 执行。
        最终结果：\(finalResult)
        下一步建议：若结果不符合预期，可直接补一句更明确的歌名或歌手名再试。
        """
    }
}

@MainActor
final class MusicFastExecutor: MusicFastExecuting {
    private let modelSlotManager: V4ModelSlotManager?
    private let generationProvider: any TextGenerationProvider

    init(
        providerSettingsStore: ProviderSettingsStore? = nil,
        generationProvider: (any TextGenerationProvider)? = nil
    ) {
        if let providerSettingsStore {
            let bridge = V4ProviderSettingsBridge(providerSettingsStore: providerSettingsStore)
            self.modelSlotManager = V4ModelSlotManager(bridge: bridge)
        } else {
            self.modelSlotManager = nil
        }
        self.generationProvider = generationProvider ?? OpenAITextGenerationProvider()
    }

    func execute(_ request: MusicFastRequest) async -> MusicFastOutcome {
        let startedAt = Date()
        let tool = V4MusicControlTool(
            modelSlotManager: modelSlotManager,
            generationProvider: generationProvider
        )
        let commandText = normalizedCommandText(intent: request.intent, query: request.query)
        let arguments: V4ToolArguments = {
            var payload: V4ToolArguments = ["command": .string(commandText)]
            if let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
                payload["query"] = .string(query)
            }
            return payload
        }()

        let runRequest = V4RunRequest(
            traceID: V4TraceID(rawValue: request.traceID),
            lane: .selectionRewrite,
            goalSummary: request.command,
            inputText: request.command,
            appName: request.focusContext.appName,
            bundleID: request.focusContext.bundleID,
            selectionText: nil,
            enabledFeatureIDs: [MagicianFeatureID.music.rawValue]
        )
        let stepRecord = V4StepRecord(
            traceID: V4TraceID(rawValue: request.traceID),
            lane: .selectionRewrite,
            goalSummary: request.command,
            title: "播放音乐",
            status: .executing,
            toolName: "apple.music.control",
            inputSummary: commandText,
            startedAt: startedAt
        )
        let context = V4ToolExecutionContext(
            toolUse: V4ToolUse(
                runID: runRequest.runID,
                stepID: stepRecord.id,
                traceID: runRequest.traceID,
                lane: runRequest.lane,
                goalSummary: runRequest.goalSummary,
                toolName: "apple.music.control",
                inputJSON: commandText,
                inputSummary: commandText,
                requestedAt: startedAt
            ),
            request: runRequest,
            step: stepRecord,
            accumulatedStepRecords: [],
            turnIndex: 1
        )

        if let semanticFailure = await tool.validateSemanticInput(arguments: arguments, context: context) {
            return MusicFastOutcome(
                status: .failed,
                message: semanticFailure.messageForUser,
                outputText: nil,
                evidenceSummary: "apple.music.control fast_path=true validation_failed=true",
                failureCode: .toolValidationFailed
            )
        }

        do {
            let output = try await tool.execute(arguments: arguments, context: context)
            let payload = output.rawPayload?.objectValue ?? [:]
            let resolvedTrack = payload["track"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedArtist = payload["artist"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let playbackState = payload["state"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedTrack = request.query?.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchedRequestedTrack = Self.matchesRequestedTrack(
                requestedTrack: requestedTrack,
                resolvedTrack: resolvedTrack,
                resolvedArtist: resolvedArtist,
                evidenceSummary: output.evidenceSummary
            )
            let confidence = request.intent == .play && requestedTrack?.isEmpty == false
                ? (matchedRequestedTrack ? "high" : "low")
                : "medium"

            if request.intent == .play {
                if !isPlaybackStateActive(playbackState) {
                    return MusicFastOutcome(
                        status: .failed,
                        message: "已定位到歌曲，但未真正开始播放，请重试。",
                        outputText: output.outputText,
                        evidenceSummary: composeFastEvidence(
                            baseEvidence: output.evidenceSummary,
                            requestedTrack: requestedTrack,
                            resolvedTrack: resolvedTrack,
                            exactMatch: matchedRequestedTrack,
                            playbackState: playbackState,
                            confidence: "low"
                        ),
                        failureCode: .verificationFailed
                    )
                }
            }

            if request.intent != .play {
                guard let playbackState, !playbackState.isEmpty else {
                    return MusicFastOutcome(
                        status: .failed,
                        message: "音乐状态读取失败，请重试。",
                        outputText: nil,
                        evidenceSummary: composeFastEvidence(
                            baseEvidence: output.evidenceSummary,
                            requestedTrack: requestedTrack,
                            resolvedTrack: resolvedTrack,
                            exactMatch: true,
                            playbackState: nil,
                            confidence: "low"
                        ),
                        failureCode: .verificationFailed
                    )
                }
            }

            let successMessage: String = {
                let defaultMessage = output.outputText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? output.outputText!
                    : "音乐操作已完成。"
                guard
                    request.intent == .play,
                    let requestedTrack,
                    !requestedTrack.isEmpty,
                    !matchedRequestedTrack
                else {
                    return defaultMessage
                }
                if defaultMessage.contains("已开始播放") {
                    return "\(defaultMessage)。请确认当前歌曲是否符合你的指令。"
                }
                return "已开始播放，请确认当前歌曲是否符合你的指令。"
            }()

            return MusicFastOutcome(
                status: .success,
                message: successMessage,
                outputText: output.outputText,
                evidenceSummary: composeFastEvidence(
                    baseEvidence: output.evidenceSummary,
                    requestedTrack: requestedTrack,
                    resolvedTrack: resolvedTrack,
                    exactMatch: request.intent == .play ? matchedRequestedTrack : true,
                    playbackState: playbackState,
                    confidence: confidence
                ),
                failureCode: nil
            )
        } catch let error as V4ToolError {
            return MusicFastOutcome(
                status: .failed,
                message: error.messageForUser,
                outputText: nil,
                evidenceSummary: "apple.music.control fast_path=true error_code=\(error.code.rawValue)",
                failureCode: error.code
            )
        } catch {
            return MusicFastOutcome(
                status: .failed,
                message: "音乐操作失败：\(error.localizedDescription)",
                outputText: nil,
                evidenceSummary: "apple.music.control fast_path=true error=unknown",
                failureCode: .toolExecutionFailed
            )
        }
    }

    private func normalizedCommandText(intent: MagicianNormalizedIntent, query: String?) -> String {
        switch intent {
        case .play:
            if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
                return "播放\(query)"
            }
            return "播放音乐"
        case .pause:
            return "暂停播放"
        case .resume:
            return "继续播放"
        case .next:
            return "下一首"
        case .previous:
            return "上一首"
        case .open:
            return "打开音乐"
        }
    }

    static func matchesRequestedTrack(
        requestedTrack: String?,
        resolvedTrack: String?,
        resolvedArtist: String?,
        evidenceSummary: String
    ) -> Bool {
        guard let requestedTrack, !requestedTrack.isEmpty else {
            return requestedTrack?.isEmpty ?? true
        }
        if magicianMusicEvidenceMatchesQuery(output: evidenceSummary, query: requestedTrack) {
            return true
        }
        var fallbackEvidence = [String]()
        if let resolvedTrack, !resolvedTrack.isEmpty {
            fallbackEvidence.append("track=\(resolvedTrack)")
        }
        if let resolvedArtist, !resolvedArtist.isEmpty {
            fallbackEvidence.append("artist=\(resolvedArtist)")
        }
        guard !fallbackEvidence.isEmpty else {
            return false
        }
        return magicianMusicEvidenceMatchesQuery(
            output: fallbackEvidence.joined(separator: "|"),
            query: requestedTrack
        )
    }

    private func isPlaybackStateActive(_ playbackState: String?) -> Bool {
        guard let playbackState else {
            return false
        }
        let normalized = playbackState
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "play" || normalized == "playing"
    }

    private func composeFastEvidence(
        baseEvidence: String,
        requestedTrack: String?,
        resolvedTrack: String?,
        exactMatch: Bool,
        playbackState: String?,
        confidence: String
    ) -> String {
        var output = baseEvidence.trimmingCharacters(in: .whitespacesAndNewlines)

        func appendField(_ key: String, _ value: String?) {
            guard let value else {
                return
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !magicianEvidenceHasField(key, in: output) else {
                return
            }
            if output.isEmpty {
                output = "\(key)=\(trimmed)"
            } else {
                output += "|\(key)=\(trimmed)"
            }
        }

        appendField("fast_path", "true")
        appendField("requested_track", requestedTrack)
        appendField("resolved_track", resolvedTrack)
        appendField("playback_state", playbackState)
        appendField("exact_match", exactMatch ? "true" : "false")
        appendField("evidence_confidence", confidence)
        return output
    }

}

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

@MainActor
protocol MusicFastExecuting {
    func execute(_ request: MusicFastRequest) async -> MusicFastOutcome
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
            enabledFeatureIDs: [MagicianFeatureID.controlMusic.rawValue]
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
            let playbackState = payload["state"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedTrack = request.query?.trimmingCharacters(in: .whitespacesAndNewlines)
            let exactMatch = isExactTrackMatch(requestedTrack: requestedTrack, resolvedTrack: resolvedTrack)

            if request.intent == .play, let requestedTrack, !requestedTrack.isEmpty, !exactMatch {
                _ = await pauseAfterMismatch(
                    tool: tool,
                    runRequest: runRequest,
                    stepRecord: stepRecord
                )
                return MusicFastOutcome(
                    status: .failed,
                    message: "资料库未找到精确匹配歌曲：\(requestedTrack)。",
                    outputText: nil,
                    evidenceSummary: composeFastEvidence(
                        baseEvidence: output.evidenceSummary,
                        requestedTrack: requestedTrack,
                        resolvedTrack: resolvedTrack,
                        exactMatch: false,
                        playbackState: playbackState,
                        confidence: "low"
                    ),
                    failureCode: .toolExecutionFailed
                )
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

            return MusicFastOutcome(
                status: .success,
                message: output.outputText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? output.outputText!
                    : "音乐操作已完成。",
                outputText: output.outputText,
                evidenceSummary: composeFastEvidence(
                    baseEvidence: output.evidenceSummary,
                    requestedTrack: requestedTrack,
                    resolvedTrack: resolvedTrack,
                    exactMatch: request.intent == .play ? exactMatch : true,
                    playbackState: playbackState,
                    confidence: request.intent == .play && requestedTrack?.isEmpty == false ? "high" : "medium"
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

    private func isExactTrackMatch(requestedTrack: String?, resolvedTrack: String?) -> Bool {
        guard
            let requestedTrack,
            let resolvedTrack,
            !requestedTrack.isEmpty,
            !resolvedTrack.isEmpty
        else {
            return requestedTrack?.isEmpty ?? true
        }
        return normalizedMusicMatchText(requestedTrack) == normalizedMusicMatchText(resolvedTrack)
    }

    private func composeFastEvidence(
        baseEvidence: String,
        requestedTrack: String?,
        resolvedTrack: String?,
        exactMatch: Bool,
        playbackState: String?,
        confidence: String
    ) -> String {
        var lines: [String] = []
        let normalizedBase = baseEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedBase.isEmpty {
            lines.append(normalizedBase)
        }
        lines.append("fast_path=true")
        if let requestedTrack, !requestedTrack.isEmpty {
            lines.append("requested_track=\(requestedTrack)")
        }
        if let resolvedTrack, !resolvedTrack.isEmpty {
            lines.append("resolved_track=\(resolvedTrack)")
        }
        if let playbackState, !playbackState.isEmpty {
            lines.append("playback_state=\(playbackState)")
        }
        lines.append("exact_match=\(exactMatch ? "true" : "false")")
        lines.append("evidence_confidence=\(confidence)")
        return lines.joined(separator: "|")
    }

    private func pauseAfterMismatch(
        tool: V4MusicControlTool,
        runRequest: V4RunRequest,
        stepRecord: V4StepRecord
    ) async -> Bool {
        let now = Date()
        let context = V4ToolExecutionContext(
            toolUse: V4ToolUse(
                runID: runRequest.runID,
                stepID: stepRecord.id,
                traceID: runRequest.traceID,
                lane: runRequest.lane,
                goalSummary: runRequest.goalSummary,
                toolName: "apple.music.control",
                inputJSON: "暂停播放",
                inputSummary: "暂停播放",
                requestedAt: now
            ),
            request: runRequest,
            step: stepRecord,
            accumulatedStepRecords: [],
            turnIndex: 1
        )
        let args: V4ToolArguments = ["command": .string("暂停播放")]
        do {
            _ = try await tool.execute(arguments: args, context: context)
            return true
        } catch {
            return false
        }
    }
}

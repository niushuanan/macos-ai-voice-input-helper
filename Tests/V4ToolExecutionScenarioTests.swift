import Foundation
import XCTest
@testable import PulseType

final class V4ToolExecutionScenarioTests: XCTestCase {
    func testTextTransformThenMailCompose() async {
        let textTool = V4TextTransformTool(
            generationProvider: StubTextGenerationProvider()
        ) { text, instruction in
            V4ToolExecutionOutput(
                outputText: "[\(instruction)] \(text)",
                evidenceSummary: "text.transform provider=test",
                rawPayload: .object(["text": .string(text)])
            )
        }
        let mailTool = V4MailComposeTool { request in
            XCTAssertEqual(request.body, "[整理成邮件] 原始纪要")
            return V4MailComposeTool.Response(
                userMessage: "邮件已填入，待你确认",
                outputText: "标题：整理后的纪要\n正文：\(request.body ?? "")",
                historyDisplayText: "邮件待确认：整理后的纪要",
                evidenceSummary: "mail_status=draft; draft_id=draft_123; recipients=team@pulsetype.ai; subject=整理后的纪要",
                verificationStatus: .verified,
                targetSummary: "team@pulsetype.ai",
                autoRepairApplied: false,
                rawFields: [
                    "mail_status": "draft",
                    "draft_id": "draft_123",
                    "recipients": "team@pulsetype.ai",
                    "subject": "整理后的纪要"
                ]
            )
        }

        let registry = V4ToolRegistry(
            tools: [textTool, mailTool],
            manifests: [
                V4ToolManifest.derived(
                    from: textTool.spec,
                    domain: "text",
                    retryPolicy: .transientSingleRetry,
                    evidenceRequirement: .summary
                ),
                V4ToolManifest.derived(
                    from: mailTool.spec,
                    domain: "mail",
                    retryPolicy: .transientSingleRetry,
                    evidenceRequirement: .structured(requiredKeys: ["mailStatus"]),
                    keywords: ["mail.compose_or_send"]
                )
            ]
        )
        let kernel = makeKernel(registry: registry)

        let transformResult = await kernel.execute(
            toolUse: makeToolUse(toolName: "text.transform", inputJSON: #"{"instruction":"整理成邮件","text":"原始纪要"}"#),
            context: makeContext(toolName: "text.transform")
        )
        XCTAssertEqual(transformResult.status, V4ToolResultStatus.success)

        let mailJSON = """
        {"body":"\(transformResult.outputText ?? "")","command":"给团队发邮件","deliveryMode":"draft_only","subject":"整理后的纪要"}
        """
        let mailResult = await kernel.execute(
            toolUse: makeToolUse(toolName: "apple.mail.compose", inputJSON: mailJSON),
            context: makeContext(toolName: "apple.mail.compose")
        )

        XCTAssertEqual(mailResult.status, V4ToolResultStatus.success)
        XCTAssertTrue(mailResult.evidenceSummary.contains("draft_id=draft_123"))
        XCTAssertTrue(mailResult.outputText?.contains("整理后的纪要") == true)
    }

    func testTextTransformUsesToolLocalPromptInsteadOfTaskWrappedUserPrompt() async throws {
        let provider = RecordingTextGenerationProvider(outputText: "```text\n润色后的文本\n```")
        let endpoint = V4ModelEndpoint(
            slot: .text,
            providerType: .localSenseVoice,
            providerIdentifier: "stub",
            providerDisplayName: "Stub",
            modelName: "stub-model",
            baseURLString: "https://example.com",
            credentialRef: V4ModelCredentialRef(rawValue: "cred"),
            localModelPath: nil,
            sourceConfigurationKey: "stub.text"
        )
        let request = V4RunRequest(
            sessionID: V4SessionID(rawValue: "session"),
            runID: V4RunID(rawValue: "run"),
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "把这段话润色一下",
            inputText: "把这段话润色一下",
            selectionText: "原始内容",
            promptStack: V4PromptStack(
                context: V4PromptContext(
                    traceID: V4TraceID(rawValue: "trace"),
                    lane: .selectionRewrite,
                    goalSummary: "把这段话润色一下",
                    inputText: "把这段话润色一下",
                    sourceAppName: nil,
                    sourceBundleID: nil,
                    selectionText: "原始内容",
                    selectedFiles: [],
                    stepRecords: [],
                    evidenceSummary: "",
                    requestedAt: Date()
                ),
                appliedLayers: [],
                finalSystemPrompt: "system",
                finalGuidancePrompt: "guidance",
                finalUserPrompt: "任务目标：把这段话润色一下\n\n待处理文本：原始内容",
                guidance: [:],
                constraints: [:],
                appliedSkillRuleIDs: [],
                createdAt: Date()
            ),
            modelSlots: V4ModelSlots(asr: endpoint, text: endpoint, agent: endpoint)
        )
        let step = V4StepRecord(
            id: V4StepID(rawValue: UUID().uuidString),
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "把这段话润色一下",
            title: "文字处理",
            status: .queued,
            toolName: "text.transform",
            inputSummary: "把这段话润色一下"
        )
        let toolUse = V4ToolUse(
            runID: V4RunID(rawValue: "run"),
            stepID: step.id,
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "把这段话润色一下",
            toolName: "text.transform",
            inputJSON: #"{"instruction":"润色得更自然","text":"原始内容"}"#,
            inputSummary: "把这段话润色一下",
            requestedAt: Date()
        )
        let context = V4ToolExecutionContext(
            toolUse: toolUse,
            request: request,
            step: step,
            accumulatedStepRecords: [],
            turnIndex: 1
        )
        let tool = V4TextTransformTool(
            generationProvider: provider
        )

        let result = try await tool.execute(
            arguments: ["instruction": .string("润色得更自然"), "text": .string("原始内容")],
            context: context
        )

        let recordedRequest = await provider.lastRequest
        XCTAssertEqual(result.outputText, "润色后的文本")
        XCTAssertEqual(recordedRequest?.userPrompt, """
        请严格根据下面的指令处理文本，并且只返回处理后的最终文本。

        处理指令：
        润色得更自然

        待处理文本：
        原始内容
        """)
        XCTAssertFalse(recordedRequest?.userPrompt.contains("任务目标：") == true)
    }

    func testTextTransformResearchPathInjectsSourcesIntoEvidence() async throws {
        let provider = RecordingTextGenerationProvider(outputText: "这是调研结果文章")
        let tool = V4TextTransformTool(
            generationProvider: provider,
            researchFetcher: { _, _ in
                [
                    V4TextTransformTool.ResearchSnippet(
                        title: "国家统计局发布2025上半年经济数据",
                        url: "https://example.com/nbs",
                        snippet: "GDP同比增长..."
                    )
                ]
            }
        )
        let endpoint = V4ModelEndpoint(
            slot: .text,
            providerType: .localSenseVoice,
            providerIdentifier: "stub",
            providerDisplayName: "Stub",
            modelName: "stub-model",
            baseURLString: "https://example.com",
            credentialRef: V4ModelCredentialRef(rawValue: "cred"),
            localModelPath: nil,
            sourceConfigurationKey: "stub.text"
        )
        let request = V4RunRequest(
            sessionID: V4SessionID(rawValue: "session"),
            runID: V4RunID(rawValue: "run"),
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "调研",
            inputText: "调研",
            modelSlots: V4ModelSlots(asr: endpoint, text: endpoint, agent: endpoint)
        )
        let step = V4StepRecord(
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "调研",
            title: "文字处理",
            status: .queued,
            toolName: "text.transform",
            inputSummary: "调研"
        )
        let context = V4ToolExecutionContext(
            toolUse: V4ToolUse(
                runID: V4RunID(rawValue: "run"),
                stepID: step.id,
                traceID: V4TraceID(rawValue: "trace"),
                lane: .selectionRewrite,
                goalSummary: "调研",
                toolName: "text.transform",
                inputJSON: "{}",
                inputSummary: "调研",
                requestedAt: Date()
            ),
            request: request,
            step: step,
            accumulatedStepRecords: [],
            turnIndex: 1
        )
        let output = try await tool.execute(
            arguments: [
                "instruction": .string("调研2025年中国上半年的经济情况，并写进备忘录"),
                "text": .string("调研2025年中国上半年的经济情况，并写进备忘录")
            ],
            context: context
        )

        XCTAssertTrue(output.evidenceSummary.contains("research_sources=1"))
        XCTAssertEqual(output.rawPayload?.objectValue?["researchQuery"]?.stringValue, "调研2025年中国上半年的经济情况，并写进备忘录")
    }

    func testTextTransformResearchRepairsMissingYearAnchor() async throws {
        let provider = SequencedRecordingTextGenerationProvider(
            outputs: [
                "这是2015年上半年中国经济简报",
                "这是2025年上半年中国经济简报"
            ]
        )
        let tool = V4TextTransformTool(
            generationProvider: provider,
            researchFetcher: { _, _ in
                [
                    V4TextTransformTool.ResearchSnippet(
                        title: "统计公报",
                        url: "https://example.com/report",
                        snippet: "包含2025年上半年关键数据"
                    )
                ]
            }
        )
        let endpoint = V4ModelEndpoint(
            slot: .text,
            providerType: .localSenseVoice,
            providerIdentifier: "stub",
            providerDisplayName: "Stub",
            modelName: "stub-model",
            baseURLString: "https://example.com",
            credentialRef: V4ModelCredentialRef(rawValue: "cred"),
            localModelPath: nil,
            sourceConfigurationKey: "stub.text"
        )
        let request = V4RunRequest(
            sessionID: V4SessionID(rawValue: "session"),
            runID: V4RunID(rawValue: "run"),
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "调研",
            inputText: "调研",
            modelSlots: V4ModelSlots(asr: endpoint, text: endpoint, agent: endpoint)
        )
        let step = V4StepRecord(
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "调研",
            title: "文字处理",
            status: .queued,
            toolName: "text.transform",
            inputSummary: "调研"
        )
        let context = V4ToolExecutionContext(
            toolUse: V4ToolUse(
                runID: V4RunID(rawValue: "run"),
                stepID: step.id,
                traceID: V4TraceID(rawValue: "trace"),
                lane: .selectionRewrite,
                goalSummary: "调研",
                toolName: "text.transform",
                inputJSON: "{}",
                inputSummary: "调研",
                requestedAt: Date()
            ),
            request: request,
            step: step,
            accumulatedStepRecords: [],
            turnIndex: 1
        )

        let output = try await tool.execute(
            arguments: [
                "instruction": .string("调研2025年中国上半年的经济情况，并写进备忘录"),
                "text": .string("调研2025年中国上半年的经济情况，并写进备忘录")
            ],
            context: context
        )

        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(output.outputText, "这是2025年上半年中国经济简报")
        XCTAssertEqual(output.rawPayload?.objectValue?["anchorRepairApplied"]?.boolValue, true)
    }

    func testFeishuCommandWithEvidenceValidation() async {
        let tool = V4FeishuCLITool { command, operation, arguments in
            XCTAssertEqual(command, "在飞书创建明天上午 10 点评审会")
            XCTAssertEqual(operation, "feishu_calendar_event")
            XCTAssertEqual(arguments, ["--title", "评审会"])
            return V4FeishuCLITool.Response(
                outputText: "{\"ok\":true}",
                userMessage: "飞书 CLI 执行成功：日程事件",
                evidenceSummary: "event_id=evt_123",
                verificationStatus: .verified,
                operation: "feishu_calendar_event"
            )
        }
        let registry = V4ToolRegistry(
            tools: [tool],
            manifests: [
                V4ToolManifest.derived(
                    from: tool.spec,
                    domain: "feishu",
                    retryPolicy: .transientDoubleRetry,
                    evidenceRequirement: .structured(requiredKeys: ["operation", "evidenceID"])
                )
            ]
        )
        let kernel = makeKernel(registry: registry)

        let result = await kernel.execute(
            toolUse: makeToolUse(
                toolName: "feishu.cli",
                inputJSON: #"{"arguments":["--title","评审会"],"command":"在飞书创建明天上午 10 点评审会","operation":"feishu_calendar_event"}"#
            ),
            context: makeContext(toolName: "feishu.cli")
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.error, nil)
        XCTAssertTrue(result.rawPayload?.contains(#""evidenceID":"evt_123""#) == true)
    }

    func testMusicControlStateTransition() async {
        let machine = FakeMusicMachine()
        let tool = V4MusicControlTool { command in
            await machine.apply(command)
        }
        let registry = V4ToolRegistry(
            tools: [tool],
            manifests: [
                V4ToolManifest.derived(
                    from: tool.spec,
                    domain: "music",
                    retryPolicy: .transientSingleRetry,
                    evidenceRequirement: .summary
                )
            ]
        )
        let kernel = makeKernel(registry: registry)

        let playResult = await kernel.execute(
            toolUse: makeToolUse(toolName: "apple.music.control", inputJSON: #"{"command":"播放稻香"}"#),
            context: makeContext(toolName: "apple.music.control")
        )
        XCTAssertEqual(playResult.status, V4ToolResultStatus.success)
        let playState = await machine.currentState()
        XCTAssertEqual(playState, "play")

        let pauseResult = await kernel.execute(
            toolUse: makeToolUse(toolName: "apple.music.control", inputJSON: #"{"command":"暂停"}"#),
            context: makeContext(toolName: "apple.music.control")
        )
        XCTAssertEqual(pauseResult.status, V4ToolResultStatus.success)
        let pauseState = await machine.currentState()
        XCTAssertEqual(pauseState, "pause")

        let resumeResult = await kernel.execute(
            toolUse: makeToolUse(toolName: "apple.music.control", inputJSON: #"{"command":"继续播放"}"#),
            context: makeContext(toolName: "apple.music.control")
        )
        XCTAssertEqual(resumeResult.status, V4ToolResultStatus.success)
        let resumeState = await machine.currentState()
        XCTAssertEqual(resumeState, "resume")
    }

    func testMusicOpenAppIntentDoesNotBecomeSearchQuery() async {
        let tool = V4MusicControlTool { command in
            XCTAssertEqual(command.action, .open)
            XCTAssertNil(command.query)
            return V4MusicControlTool.ResultPayload(
                action: .open,
                state: "open",
                track: nil,
                artist: nil,
                evidence: "state=open"
            )
        }

        let output = try? await tool.execute(
            arguments: ["command": .string("打开音乐")],
            context: makeContext(toolName: "apple.music.control")
        )
        XCTAssertTrue((output?.outputText ?? "").contains("已打开 Music"))
    }

    func testMusicStructuredEvidenceStillPassesWhenStateEmptyFromExecutor() async {
        let tool = V4MusicControlTool { command in
            XCTAssertEqual(command.action, .play)
            return V4MusicControlTool.ResultPayload(
                action: .play,
                state: "   ",
                track: "稻香",
                artist: "周杰伦",
                evidence: "track=稻香|artist=周杰伦"
            )
        }
        let registry = V4ToolRegistry(
            tools: [tool],
            manifests: [
                V4ToolManifest.derived(
                    from: tool.spec,
                    domain: "music",
                    retryPolicy: .transientSingleRetry,
                    evidenceRequirement: .structured(requiredKeys: ["action", "state"])
                )
            ]
        )
        let kernel = makeKernel(registry: registry)
        let result = await kernel.execute(
            toolUse: makeToolUse(toolName: "apple.music.control", inputJSON: #"{"command":"播放稻香"}"#),
            context: makeContext(toolName: "apple.music.control")
        )
        XCTAssertEqual(result.status, .success)
        XCTAssertNil(result.error)
        XCTAssertTrue((result.evidenceSummary).contains("state=play"))
    }

    func testMusicSongQueryVariantKeepsHighConfidenceWhenResolvedTrackMatches() async throws {
        let tool = V4MusicControlTool { command in
            XCTAssertEqual(command.action, .play)
            XCTAssertEqual(command.query, "稻香")
            return V4MusicControlTool.ResultPayload(
                action: .play,
                state: "play",
                track: "稻香",
                artist: "周杰伦",
                evidence: "track=稻香|artist=周杰伦|state=play"
            )
        }

        let output = try await tool.execute(
            arguments: ["command": .string("播放周杰伦的《稻香》")],
            context: makeContext(toolName: "apple.music.control")
        )

        XCTAssertTrue(output.evidenceSummary.contains("exact_match=true"))
        XCTAssertTrue(output.evidenceSummary.contains("evidence_confidence=high"))
        XCTAssertEqual(output.rawPayload?.objectValue?["exactMatch"]?.boolValue, true)
        XCTAssertEqual(output.rawPayload?.objectValue?["evidenceConfidence"]?.stringValue, "high")
        XCTAssertEqual(magicianEvidenceField("track", from: output.evidenceSummary), "稻香")
        XCTAssertEqual(magicianEvidenceField("artist", from: output.evidenceSummary), "周杰伦")
        XCTAssertEqual(magicianEvidenceField("requested_track", from: output.evidenceSummary), "稻香")
        XCTAssertEqual(magicianEvidenceField("resolved_track", from: output.evidenceSummary), "稻香")
        XCTAssertEqual(magicianEvidenceField("playback_state", from: output.evidenceSummary), "play")
        XCTAssertEqual(magicianEvidenceField("exact_match", from: output.evidenceSummary), "true")
        XCTAssertEqual(magicianEvidenceField("evidence_confidence", from: output.evidenceSummary), "high")
        XCTAssertEqual(evidenceFieldOccurrenceCount("track", in: output.evidenceSummary), 1)
        XCTAssertEqual(evidenceFieldOccurrenceCount("artist", in: output.evidenceSummary), 1)
        XCTAssertEqual(evidenceFieldOccurrenceCount("requested_track", in: output.evidenceSummary), 1)
        XCTAssertEqual(evidenceFieldOccurrenceCount("resolved_track", in: output.evidenceSummary), 1)
        XCTAssertEqual(evidenceFieldOccurrenceCount("playback_state", in: output.evidenceSummary), 1)
        XCTAssertEqual(evidenceFieldOccurrenceCount("exact_match", in: output.evidenceSummary), 1)
        XCTAssertEqual(evidenceFieldOccurrenceCount("evidence_confidence", in: output.evidenceSummary), 1)
    }

    func testMusicDryRunSkipsExecutionHandler() async throws {
        let tool = V4MusicControlTool { _ in
            XCTFail("dry run 不应触发执行器")
            return V4MusicControlTool.ResultPayload(
                action: .play,
                state: "play",
                track: nil,
                artist: nil,
                evidence: "state=play"
            )
        }

        let output = try await tool.execute(
            arguments: ["command": .string("播放稻香 --dry-run")],
            context: makeContext(toolName: "apple.music.control")
        )
        XCTAssertTrue((output.outputText ?? "").contains("演练完成"))
        XCTAssertEqual(output.evidenceSummary, "apple.music.control dry_run=true")
    }

    func testMusicMismatchEvidenceDowngradesToLowConfidenceInsteadOfFailing() {
        let evidence = V4MusicControlTool.normalizedPlaybackEvidenceForMismatch(
            rawOutput: "",
            query: "印第安老斑鸠",
            action: .play
        )

        XCTAssertTrue(evidence.contains("state=play"))
        XCTAssertTrue(evidence.contains("track=印第安老斑鸠"))
        XCTAssertTrue(evidence.contains("evidence_confidence=low"))
        XCTAssertTrue(evidence.contains("query_mismatch=true"))
    }

    func testMusicDeterministicTrackSelectionPrefersExactSongMatch() {
        let tracks = [
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-1",
                name: "七里香",
                artist: "周杰伦",
                album: "七里香"
            ),
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-2",
                name: "稻香",
                artist: "周杰伦",
                album: "魔杰座"
            ),
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-3",
                name: "龙战骑士",
                artist: "周杰伦",
                album: "魔杰座"
            )
        ]

        let picked = V4MusicControlTool.selectDeterministicTrack(
            query: "稻香",
            rawCommand: "播放稻香",
            playIntent: .song,
            tracks: tracks
        )

        XCTAssertEqual(picked?.persistentID, "id-2")
    }

    func testMusicPreferredLocalTrackUsesUniqueExactSongMatchBeforeLLM() {
        let tracks = [
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-1",
                name: "跨时代",
                artist: "周杰伦",
                album: "跨时代"
            ),
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-2",
                name: "青花瓷",
                artist: "周杰伦",
                album: "我很忙"
            )
        ]

        let picked = V4MusicControlTool.preferredLocalTrack(
            query: "周杰伦的跨时代",
            rawCommand: "播放周杰伦的跨时代",
            playIntent: .song,
            tracks: tracks
        )

        XCTAssertEqual(picked?.persistentID, "id-1")
    }

    func testMusicPreferredLocalTrackUsesArtistHintToBreakExactSongTie() {
        let tracks = [
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-1",
                name: "夜曲",
                artist: "周杰伦",
                album: "十一月的萧邦"
            ),
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-2",
                name: "夜曲",
                artist: "其他歌手",
                album: "翻唱集"
            )
        ]

        let picked = V4MusicControlTool.preferredLocalTrack(
            query: "周杰伦的夜曲",
            rawCommand: "播放周杰伦的夜曲",
            playIntent: .song,
            tracks: tracks
        )

        XCTAssertEqual(picked?.persistentID, "id-1")
    }

    func testMusicPreferredLocalTrackReturnsNilWhenExactSongStillAmbiguous() {
        let tracks = [
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-1",
                name: "夜曲",
                artist: "周杰伦",
                album: "十一月的萧邦"
            ),
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-2",
                name: "夜曲",
                artist: "周杰伦",
                album: "演唱会 Live"
            )
        ]

        let picked = V4MusicControlTool.preferredLocalTrack(
            query: "夜曲",
            rawCommand: "播放夜曲",
            playIntent: .song,
            tracks: tracks
        )

        XCTAssertNil(picked)
    }

    func testMusicDeterministicTrackSelectionSkipsMoodFallback() {
        let tracks = [
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-1",
                name: "晴天",
                artist: "周杰伦",
                album: "叶惠美"
            )
        ]

        let picked = V4MusicControlTool.selectDeterministicTrack(
            query: "开心",
            rawCommand: "放一首开心的歌",
            playIntent: .mood,
            tracks: tracks
        )

        XCTAssertNil(picked)
    }

    func testMusicRotatedLibraryTracksStartsAtRequestedTrackAndWraps() {
        let tracks = [
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-1",
                name: "A",
                artist: "周杰伦",
                album: "甲"
            ),
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-2",
                name: "B",
                artist: "周杰伦",
                album: "乙"
            ),
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-3",
                name: "C",
                artist: "周杰伦",
                album: "丙"
            ),
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-4",
                name: "D",
                artist: "周杰伦",
                album: "丁"
            )
        ]

        let rotated = V4MusicControlTool.rotatedLibraryTracks(
            startingAtPersistentID: "id-3",
            tracks: tracks
        )

        XCTAssertEqual(rotated?.map(\.persistentID), ["id-3", "id-4", "id-1", "id-2"])
    }

    func testMusicAdjacentLibraryTrackWrapsForwardToLibraryHead() {
        let tracks = [
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-1",
                name: "A",
                artist: "周杰伦",
                album: "甲"
            ),
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-2",
                name: "B",
                artist: "周杰伦",
                album: "乙"
            ),
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-3",
                name: "C",
                artist: "周杰伦",
                album: "丙"
            )
        ]

        let target = V4MusicControlTool.adjacentLibraryTrack(
            currentPersistentID: "id-3",
            direction: .next,
            tracks: tracks
        )

        XCTAssertEqual(target?.persistentID, "id-1")
    }

    func testMusicAdjacentLibraryTrackWrapsBackwardToLibraryTail() {
        let tracks = [
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-1",
                name: "A",
                artist: "周杰伦",
                album: "甲"
            ),
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-2",
                name: "B",
                artist: "周杰伦",
                album: "乙"
            ),
            V4MusicControlTool.LibraryTrackRecord(
                persistentID: "id-3",
                name: "C",
                artist: "周杰伦",
                album: "丙"
            )
        ]

        let target = V4MusicControlTool.adjacentLibraryTrack(
            currentPersistentID: "id-1",
            direction: .previous,
            tracks: tracks
        )

        XCTAssertEqual(target?.persistentID, "id-3")
    }

    func testMusicVerificationAcceptsResolvedIDSubstitutionWhenMetadataMatches() {
        let verification = V4MusicControlTool.verifyLibraryPlayback(
            output: "track=龙战骑士|artist=周杰伦|album=魔杰座|state=playing|resolved_id=substitute-id|target_id_match=false|metadata_match=true|resolved_id_substituted=true",
            targetID: "target-id",
            query: "龙战骑士",
            playIntent: .song
        )

        XCTAssertTrue(verification.playbackActive)
        XCTAssertTrue(verification.metadataMatches)
        XCTAssertFalse(verification.targetIDMatches)
        XCTAssertTrue(verification.queryMatches)
        XCTAssertTrue(verification.isAccepted)
    }

    func testMusicVerificationRejectsPlayingWrongSong() {
        let verification = V4MusicControlTool.verifyLibraryPlayback(
            output: "track=鞋子特大号|artist=周杰伦|album=哎呦，不错哦|state=playing|resolved_id=other-id|target_id_match=false|metadata_match=false",
            targetID: "target-id",
            query: "稻香",
            playIntent: .song
        )

        XCTAssertTrue(verification.playbackActive)
        XCTAssertFalse(verification.metadataMatches)
        XCTAssertFalse(verification.targetIDMatches)
        XCTAssertFalse(verification.queryMatches)
        XCTAssertFalse(verification.isAccepted)
    }

    func testMusicAlbumIntentMarksPlayIntentAsAlbum() async {
        let tool = V4MusicControlTool { command in
            XCTAssertEqual(command.action, .play)
            XCTAssertEqual(command.playIntent, .album)
            XCTAssertEqual(command.query, "范特西专辑")
            return V4MusicControlTool.ResultPayload(
                action: .play,
                state: "play",
                track: "简单爱",
                artist: "周杰伦",
                evidence: "track=简单爱|artist=周杰伦|album=范特西|state=play|strategy=library_album"
            )
        }
        _ = try? await tool.execute(
            arguments: ["command": .string("播放范特西专辑")],
            context: makeContext(toolName: "apple.music.control")
        )
    }

    func testMusicMoodIntentExtractsMoodKeyword() async {
        let tool = V4MusicControlTool { command in
            XCTAssertEqual(command.action, .play)
            XCTAssertEqual(command.playIntent, .mood)
            XCTAssertEqual(command.query, "开心")
            return V4MusicControlTool.ResultPayload(
                action: .play,
                state: "play",
                track: "告白气球",
                artist: "周杰伦",
                evidence: "track=告白气球|artist=周杰伦|album=周杰伦的床边故事|state=play|strategy=library_song"
            )
        }
        _ = try? await tool.execute(
            arguments: ["command": .string("我很悲伤，要播放一首开心的歌")],
            context: makeContext(toolName: "apple.music.control")
        )
    }

    func testMusicMoodSceneUsesSemanticResolver() async {
        let tool = V4MusicControlTool(
            executeHandler: { command in
                XCTAssertEqual(command.action, .play)
                XCTAssertEqual(command.playIntent, .mood)
                XCTAssertEqual(command.query, "治愈 轻松")
                return V4MusicControlTool.ResultPayload(
                    action: .play,
                    state: "play",
                    track: "晴天",
                    artist: "周杰伦",
                    evidence: "track=晴天|artist=周杰伦|album=叶惠美|state=play|strategy=library_song"
                )
            },
            semanticResolver: { command, _ in
                guard command == "我很悲伤，放首歌" else {
                    return nil
                }
                return V4MusicControlTool.SemanticPlayDecision(
                    query: "治愈 轻松",
                    intent: .mood,
                    confidence: 0.92,
                    reason: "场景情绪请求"
                )
            }
        )
        _ = try? await tool.execute(
            arguments: ["command": .string("我很悲伤，放首歌")],
            context: makeContext(toolName: "apple.music.control")
        )
    }

    func testMusicFuzzyIntentUsesSemanticResolver() async {
        let tool = V4MusicControlTool(
            executeHandler: { command in
                XCTAssertEqual(command.action, .play)
                XCTAssertEqual(command.playIntent, .mood)
                XCTAssertEqual(command.query, "通勤 轻快")
                return V4MusicControlTool.ResultPayload(
                    action: .play,
                    state: "play",
                    track: "一路向北",
                    artist: "周杰伦",
                    evidence: "track=一路向北|artist=周杰伦|album=十一月的萧邦|state=play|strategy=library_song"
                )
            },
            semanticResolver: { command, _ in
                guard command == "通勤路上来点歌" else {
                    return nil
                }
                return V4MusicControlTool.SemanticPlayDecision(
                    query: "通勤 轻快",
                    intent: .mood,
                    confidence: 0.88,
                    reason: "模糊场景意图"
                )
            }
        )
        _ = try? await tool.execute(
            arguments: ["command": .string("通勤路上来点歌")],
            context: makeContext(toolName: "apple.music.control")
        )
    }

    func testAppleNotesDryRunSkipsAutomation() async throws {
        let tool = V4AppleNotesTool()
        let output = try await tool.execute(
            arguments: [
                "command": .string("写入备忘录 --dry-run"),
                "title": .string("测试标题"),
                "body": .string("测试正文")
            ],
            context: makeContext(toolName: "apple.notes.create")
        )

        XCTAssertTrue((output.outputText ?? "").contains("演练完成"))
        XCTAssertEqual(output.evidenceSummary, "apple.notes.create action=create; dry_run=true")
    }

    func testAppleNotesAppendDryRun() async throws {
        let tool = V4AppleNotesTool()
        let output = try await tool.execute(
            arguments: [
                "command": .string("把这段补充到周会纪要 --dry-run"),
                "action": .string("append"),
                "targetTitle": .string("周会纪要"),
                "body": .string("补充内容")
            ],
            context: makeContext(toolName: "apple.notes.create")
        )

        XCTAssertEqual(output.evidenceSummary, "apple.notes.create action=append; dry_run=true")
        XCTAssertEqual(output.rawPayload?.objectValue?["action"]?.stringValue, "append")
    }

    func testAppleNotesFindDryRun() async throws {
        let tool = V4AppleNotesTool()
        let output = try await tool.execute(
            arguments: [
                "command": .string("查找项目周报 --dry-run"),
                "action": .string("find"),
                "query": .string("项目周报")
            ],
            context: makeContext(toolName: "apple.notes.create")
        )

        XCTAssertEqual(output.evidenceSummary, "apple.notes.create action=find; dry_run=true")
        XCTAssertEqual(output.rawPayload?.objectValue?["action"]?.stringValue, "find")
    }

    func testAppleNotesDryRunAcceptsCommandFieldViaKernelValidation() async {
        let tool = V4AppleNotesTool()
        let registry = V4ToolRegistry(
            tools: [tool],
            manifests: [
                V4ToolManifest.derived(
                    from: tool.spec,
                    domain: "notes",
                    retryPolicy: .transientSingleRetry,
                    evidenceRequirement: .structured(requiredKeys: ["action"])
                )
            ]
        )
        let kernel = makeKernel(registry: registry)

        let result = await kernel.execute(
            toolUse: makeToolUse(
                toolName: "apple.notes.create",
                inputJSON: #"{"command":"写入备忘录 --dry-run","action":"create","title":"标题","body":"正文"}"#
            ),
            context: makeContext(toolName: "apple.notes.create")
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.error, nil)
        XCTAssertEqual(result.evidenceSummary, "apple.notes.create action=create; dry_run=true")
    }

    func testAppleNotesDryRunIgnoresUnknownFields() async {
        let tool = V4AppleNotesTool()
        let registry = V4ToolRegistry(
            tools: [tool],
            manifests: [
                V4ToolManifest.derived(
                    from: tool.spec,
                    domain: "notes",
                    retryPolicy: .transientSingleRetry,
                    evidenceRequirement: .structured(requiredKeys: ["action"])
                )
            ]
        )
        let kernel = makeKernel(registry: registry)

        let result = await kernel.execute(
            toolUse: makeToolUse(
                toolName: "apple.notes.create",
                inputJSON: #"{"command":"写入备忘录 --dry-run","action":"create","title":"标题","body":"正文","unknown":"x"}"#
            ),
            context: makeContext(toolName: "apple.notes.create")
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertNil(result.error)
    }

    func testAppleNotesInvalidActionFailsSemanticValidation() async {
        let tool = V4AppleNotesTool()
        let registry = V4ToolRegistry(
            tools: [tool],
            manifests: [
                V4ToolManifest.derived(
                    from: tool.spec,
                    domain: "notes",
                    retryPolicy: .transientSingleRetry,
                    evidenceRequirement: .structured(requiredKeys: ["action"])
                )
            ]
        )
        let kernel = makeKernel(registry: registry)

        let result = await kernel.execute(
            toolUse: makeToolUse(
                toolName: "apple.notes.create",
                inputJSON: #"{"action":"draft","title":"标题","body":"正文"}"#
            ),
            context: makeContext(toolName: "apple.notes.create")
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error?.code, .toolValidationFailed)
    }

    func testAppleNotesCreateSucceedsOnlyAfterVerifiedNoteEvidence() async throws {
        actor ScriptStub {
            var count = 0

            func run(lines _: [String], arguments: [String]) -> MagicianProcessResult {
                count += 1
                if arguments.count == 2 {
                    return MagicianProcessResult(exitCode: 0, stdout: "x-coredata://NOTE/1", stderr: "")
                }
                return MagicianProcessResult(
                    exitCode: 0,
                    stdout: "x-coredata://NOTE/1\u{1F}测试标题\u{1E}<div>测试正文</div>",
                    stderr: ""
                )
            }
        }

        let stub = ScriptStub()
        let tool = V4AppleNotesTool(
            appleScriptRunner: { lines, arguments, _, _ in
                await stub.run(lines: lines, arguments: arguments)
            }
        )

        let output = try await tool.execute(
            arguments: [
                "action": .string("create"),
                "title": .string("测试标题"),
                "body": .string("测试正文")
            ],
            context: makeContext(toolName: "apple.notes.create")
        )

        XCTAssertEqual(output.evidenceSummary, "apple.notes.create action=create; note_id=x-coredata://NOTE/1")
        XCTAssertEqual(output.rawPayload?.objectValue?["layer"]?.stringValue, "applescript")
    }

    func testAppleNotesCreateRejectsUnverifiedFakeSuccess() async {
        actor ScriptStub {
            func run(lines _: [String], arguments _: [String]) -> MagicianProcessResult {
                MagicianProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        }

        let stub = ScriptStub()
        let tool = V4AppleNotesTool(
            appleScriptRunner: { lines, arguments, _, _ in
                await stub.run(lines: lines, arguments: arguments)
            }
        )

        do {
            _ = try await tool.execute(
                arguments: [
                    "action": .string("create"),
                    "title": .string("测试标题"),
                    "body": .string("测试正文")
                ],
                context: makeContext(toolName: "apple.notes.create")
            )
            XCTFail("expected execute to fail when note evidence is missing")
        } catch let toolError as V4ToolError {
            XCTAssertEqual(toolError.code, .toolExecutionFailed)
            XCTAssertEqual(toolError.toolID, "apple.notes.create")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testAppleNotesCreateFallsBackToShortcutsWhenAppleScriptFails() async throws {
        actor ScriptStub {
            private(set) var callCount = 0

            func run(lines _: [String], arguments _: [String]) -> MagicianProcessResult {
                callCount += 1
                return MagicianProcessResult(
                    exitCode: 1,
                    stdout: "",
                    stderr: "Not authorized to send Apple events to Notes. (-1743)"
                )
            }
        }

        actor ShortcutStub {
            private(set) var callCount = 0

            func run(name _: String, inputText _: String?) -> MagicianProcessResult {
                callCount += 1
                return MagicianProcessResult(
                    exitCode: 0,
                    stdout: "x-coredata://NOTE/SHORTCUT-1",
                    stderr: ""
                )
            }
        }

        let scriptStub = ScriptStub()
        let shortcutStub = ShortcutStub()
        let tool = V4AppleNotesTool(
            appleScriptRunner: { lines, arguments, _, _ in
                await scriptStub.run(lines: lines, arguments: arguments)
            },
            shortcutRunner: { name, inputText, _, _ in
                await shortcutStub.run(name: name, inputText: inputText)
            },
            shortcutAvailability: { true }
        )

        let output = try await tool.execute(
            arguments: [
                "action": .string("create"),
                "title": .string("测试标题"),
                "body": .string("测试正文")
            ],
            context: makeContext(toolName: "apple.notes.create")
        )

        XCTAssertEqual(output.rawPayload?.objectValue?["layer"]?.stringValue, "shortcuts")
        XCTAssertEqual(output.evidenceSummary, "apple.notes.create action=create; note_id=x-coredata://NOTE/SHORTCUT-1")
        let scriptCalls = await scriptStub.callCount
        let shortcutCalls = await shortcutStub.callCount
        XCTAssertEqual(scriptCalls, 1)
        XCTAssertEqual(shortcutCalls, 1)
    }

    func testAppleNotesCreateFailureContainsLayerDetails() async {
        actor ScriptStub {
            func run(lines _: [String], arguments _: [String]) -> MagicianProcessResult {
                MagicianProcessResult(
                    exitCode: 1,
                    stdout: "",
                    stderr: "Not authorized to send Apple events to Notes. (-1743)"
                )
            }
        }

        actor ShortcutStub {
            func run(name _: String, inputText _: String?) -> MagicianProcessResult {
                MagicianProcessResult(exitCode: -1, stdout: "", stderr: "shortcut not found")
            }
        }

        let scriptStub = ScriptStub()
        let shortcutStub = ShortcutStub()
        let tool = V4AppleNotesTool(
            appleScriptRunner: { lines, arguments, _, _ in
                await scriptStub.run(lines: lines, arguments: arguments)
            },
            shortcutRunner: { name, inputText, _, _ in
                await shortcutStub.run(name: name, inputText: inputText)
            },
            shortcutAvailability: { true }
        )

        do {
            _ = try await tool.execute(
                arguments: [
                    "action": .string("create"),
                    "title": .string("测试标题"),
                    "body": .string("测试正文")
                ],
                context: makeContext(toolName: "apple.notes.create")
            )
            XCTFail("expected create to fail")
        } catch let toolError as V4ToolError {
            XCTAssertEqual(toolError.code, .toolExecutionFailed)
            XCTAssertEqual(toolError.recoverAction, "open_notes_automation_permission")
            XCTAssertTrue(toolError.userMessage.contains("Notes 操作失败"))
            XCTAssertTrue((toolError.debugMessage ?? "").contains("applescript:exit=1"))
            XCTAssertTrue((toolError.debugMessage ?? "").contains("shortcuts:exit=-1"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testCalendarCreateWithTimeParseFallback() async {
        let recorder = CalendarRequestRecorder()
        let tool = V4CalendarCreateTool { request in
            await recorder.record(request)
            return V4CalendarCreateTool.ResultPayload(
                eventIdentifier: "evt_001",
                title: request.title,
                startAt: request.startAt,
                endAt: request.endAt,
                location: request.location,
                notes: request.notes
            )
        }
        let registry = V4ToolRegistry(
            tools: [tool],
            manifests: [
                V4ToolManifest.derived(
                    from: tool.spec,
                    domain: "calendar",
                    retryPolicy: .transientSingleRetry,
                    evidenceRequirement: .structured(requiredKeys: ["eventID", "startAt", "endAt"])
                )
            ]
        )
        let kernel = makeKernel(registry: registry)

        let result = await kernel.execute(
            toolUse: makeToolUse(toolName: "apple.calendar.create", inputJSON: #"{"command":"明天下午3点和产品评审"}"#),
            context: makeContext(toolName: "apple.calendar.create")
        )

        XCTAssertEqual(result.status, V4ToolResultStatus.success)
        let request = await recorder.latest
        XCTAssertNotNil(request?.startAt)
        XCTAssertEqual(request?.title, "明天下午3点和产品评审")
    }

    func testMailCommandInfersAutoSendWithoutUsingRawCommandAsBody() async {
        let tool = V4MailComposeTool { request in
            XCTAssertEqual(request.deliveryMode, .autoSendIfResolved)
            XCTAssertNil(request.body)
            XCTAssertEqual(request.command, "给产品组发邮件说今晚评审延后半小时")
            return V4MailComposeTool.Response(
                userMessage: "邮件已发出",
                outputText: nil,
                historyDisplayText: "邮件已发出",
                evidenceSummary: "mail_status=sent; message_id=msg_123; recipients=team@pulsetype.ai; subject=评审延后通知",
                verificationStatus: .verified,
                targetSummary: "team@pulsetype.ai",
                autoRepairApplied: false,
                rawFields: [
                    "mail_status": "sent",
                    "message_id": "msg_123",
                    "recipients": "team@pulsetype.ai",
                    "subject": "评审延后通知"
                ]
            )
        }
        let registry = V4ToolRegistry(
            tools: [tool],
            manifests: [
                V4ToolManifest.derived(
                    from: tool.spec,
                    domain: "mail",
                    retryPolicy: .transientSingleRetry,
                    evidenceRequirement: .structured(requiredKeys: ["mailStatus"])
                )
            ]
        )
        let kernel = makeKernel(registry: registry)

        let result = await kernel.execute(
            step: V4StepRecord(
                traceID: V4TraceID(rawValue: "trace"),
                lane: .selectionRewrite,
                goalSummary: "goal",
                title: "整理邮件",
                status: .queued,
                toolName: "apple.mail.compose",
                inputSummary: "给产品组发邮件说今晚评审延后半小时"
            ),
            request: V4RunRequest(
                sessionID: V4SessionID(rawValue: "session"),
                runID: V4RunID(rawValue: "run"),
                traceID: V4TraceID(rawValue: "trace"),
                lane: .selectionRewrite,
                goalSummary: "goal",
                inputText: "给产品组发邮件说今晚评审延后半小时"
            ),
            accumulatedStepRecords: [],
            turnIndex: 1
        )

        XCTAssertEqual(result.status, .success)
    }

    func testRetryPolicyOnRetryableError() async {
        let tool = RetryableTestTool()
        let manifest = V4ToolManifest(
            toolID: tool.spec.toolID,
            displayName: tool.spec.displayName,
            domain: "test",
            requiredFeature: nil,
            inputSchemaSummary: "无输入",
            isConcurrencySafe: true,
            retryPolicy: V4ToolRetryPolicy(maxRetryCount: 1, retryableCodes: [.toolExecutionFailed]),
            evidenceRequirement: .none
        )
        let kernel = makeKernel(registry: V4ToolRegistry(tools: [tool], manifests: [manifest]))

        let first = await kernel.execute(
            toolUse: makeToolUse(toolName: "retry.tool", inputJSON: "{}"),
            context: makeContext(toolName: "retry.tool", attemptCount: 1)
        )
        XCTAssertEqual(first.status, V4ToolResultStatus.failed)
        XCTAssertEqual(first.error?.code, .toolExecutionFailed)
        XCTAssertEqual(first.error?.isRetryable, true)

        let second = await kernel.execute(
            toolUse: makeToolUse(toolName: "retry.tool", inputJSON: "{}"),
            context: makeContext(toolName: "retry.tool", attemptCount: 2)
        )
        XCTAssertEqual(second.status, V4ToolResultStatus.failed)
        XCTAssertEqual(second.error?.isRetryable, false)
    }

    func testMissingEvidenceIsFailure() async {
        let tool = V4FeishuCLITool { _, _, _ in
            V4FeishuCLITool.Response(
                outputText: "{\"ok\":true}",
                userMessage: "飞书 CLI 执行成功",
                evidenceSummary: nil,
                verificationStatus: .verified,
                operation: "feishu_calendar_event"
            )
        }
        let registry = V4ToolRegistry(
            tools: [tool],
            manifests: [
                V4ToolManifest.derived(
                    from: tool.spec,
                    domain: "feishu",
                    retryPolicy: .transientDoubleRetry,
                    evidenceRequirement: .structured(requiredKeys: ["operation", "evidenceID"])
                )
            ]
        )
        let kernel = makeKernel(registry: registry)

        let result = await kernel.execute(
            toolUse: makeToolUse(
                toolName: "feishu.cli",
                inputJSON: #"{"command":"在飞书创建日程","operation":"feishu_calendar_event"}"#
            ),
            context: makeContext(toolName: "feishu.cli")
        )

        XCTAssertEqual(result.status, V4ToolResultStatus.failed)
        XCTAssertEqual(result.error?.code, .verificationFailed)
    }

    private func makeKernel(registry: V4ToolRegistry) -> V4ToolKernel {
        V4ToolKernel(
            registry: registry,
            permissionGate: TestPermissionGate(),
            hookPipeline: V4ToolHookPipeline()
        )
    }

    private func makeToolUse(
        toolName: String,
        inputJSON: String
    ) -> V4ToolUse {
        V4ToolUse(
            runID: V4RunID(rawValue: "run"),
            stepID: V4StepID(rawValue: UUID().uuidString),
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "goal",
            toolName: toolName,
            inputJSON: inputJSON,
            inputSummary: "summary",
            requestedAt: Date()
        )
    }

    private func makeContext(
        toolName: String,
        attemptCount: Int = 1
    ) -> V4ToolExecutionContext {
        let step = V4StepRecord(
            id: V4StepID(rawValue: UUID().uuidString),
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "goal",
            title: toolName,
            status: .queued,
            toolName: toolName,
            inputSummary: "summary",
            attemptCount: attemptCount
        )
        let toolUse = V4ToolUse(
            runID: V4RunID(rawValue: "run"),
            stepID: step.id,
            traceID: V4TraceID(rawValue: "trace"),
            lane: .selectionRewrite,
            goalSummary: "goal",
            toolName: toolName,
            inputJSON: "{}",
            inputSummary: "summary",
            requestedAt: Date()
        )
        return V4ToolExecutionContext(
            toolUse: toolUse,
            request: V4RunRequest(
                sessionID: V4SessionID(rawValue: "session"),
                runID: V4RunID(rawValue: "run"),
                traceID: V4TraceID(rawValue: "trace"),
                lane: .selectionRewrite,
                goalSummary: "goal",
                inputText: "input"
            ),
            step: step,
            accumulatedStepRecords: [],
            turnIndex: 1
        )
    }
}

private func evidenceFieldOccurrenceCount(_ key: String, in text: String) -> Int {
    let pattern = #"(?:(?<=^)|(?<=[\|\s;]))\#(NSRegularExpression.escapedPattern(for: key))=(.+?)(?=(?:[\|;]|\s+[A-Za-z_]+=|$))"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return 0
    }
    let range = NSRange(location: 0, length: (text as NSString).length)
    return regex.numberOfMatches(in: text, options: [], range: range)
}

private struct TestPermissionGate: V4ToolPermissionChecking {
    func evaluate(spec: V4ToolSpec, request: V4RunRequest) async -> V4PermissionDecision {
        V4PermissionDecision(
            behavior: .allow,
            traceID: request.traceID,
            lane: request.lane,
            toolName: spec.toolName,
            reason: "test_allow",
            userMessage: nil
        )
    }
}

private actor FakeMusicMachine {
    private(set) var state: String = "idle"

    func apply(_ command: V4MusicControlTool.Command) -> V4MusicControlTool.ResultPayload {
        switch command.action {
        case .open:
            state = "open"
            return .init(action: .open, state: state, track: nil, artist: nil, evidence: "state=open")
        case .play:
            state = "play"
            return .init(action: .play, state: state, track: "稻香", artist: "周杰伦", evidence: "track=稻香|artist=周杰伦|state=play")
        case .pause:
            state = "pause"
            return .init(action: .pause, state: state, track: nil, artist: nil, evidence: "state=pause")
        case .resume:
            state = "resume"
            return .init(action: .resume, state: state, track: nil, artist: nil, evidence: "state=resume")
        case .next:
            state = "next"
            return .init(action: .next, state: state, track: nil, artist: nil, evidence: "state=next")
        case .previous:
            state = "previous"
            return .init(action: .previous, state: state, track: nil, artist: nil, evidence: "state=previous")
        }
    }

    func currentState() -> String {
        state
    }
}

private actor CalendarRequestRecorder {
    private(set) var latest: V4CalendarCreateTool.Request?

    func record(_ request: V4CalendarCreateTool.Request) {
        latest = request
    }
}

private struct RetryableTestTool: V4Tool {
    let spec = V4ToolSpec(
        toolName: "retry.tool",
        displayName: "retry",
        summary: "retry",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(fields: []),
        requiresPermission: false,
        requiredFeature: nil,
        isConcurrencySafe: true,
        mutatesUserData: false,
        supportsStreamingResults: false
    )

    func execute(
        arguments _: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        throw V4ToolError(
            code: .toolExecutionFailed,
            toolID: spec.toolID,
            messageForUser: "暂时失败",
            messageForDebug: "retryable failure",
            recoverAction: "retry_command",
            isRetryable: true
        )
    }
}

private final class StubTextGenerationProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAI, .openAICompatible]

    func generateText(
        request _: TextGenerationRequest,
        configuration _: TextGenerationProviderConfiguration,
        apiKey _: String
    ) async throws -> TextGenerationResult {
        TextGenerationResult(
            providerType: .openAI,
            providerName: "stub",
            modelName: "stub-model",
            outputText: "stub"
        )
    }
}

private actor RecordingTextGenerationProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAI, .openAICompatible, .localSenseVoice]

    private(set) var lastRequest: TextGenerationRequest?
    private let outputText: String

    init(outputText: String) {
        self.outputText = outputText
    }

    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey _: String
    ) async throws -> TextGenerationResult {
        lastRequest = request
        return TextGenerationResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            outputText: outputText
        )
    }
}

private actor SequencedRecordingTextGenerationProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAI, .openAICompatible, .localSenseVoice]
    private var outputs: [String]
    private(set) var callCount: Int = 0

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func generateText(
        request _: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey _: String
    ) async throws -> TextGenerationResult {
        callCount += 1
        let output = outputs.isEmpty ? "" : outputs.removeFirst()
        return TextGenerationResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            outputText: output
        )
    }
}

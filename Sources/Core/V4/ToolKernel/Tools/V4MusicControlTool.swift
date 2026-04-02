import Foundation

struct V4MusicControlTool: V4Tool {
    enum Action: String, Equatable, Sendable {
        case open
        case play
        case pause
        case resume
        case next
        case previous
    }

    struct Command: Equatable, Sendable {
        let action: Action
        let query: String?
    }

    struct ResultPayload: Equatable, Sendable {
        let action: Action
        let state: String
        let track: String?
        let artist: String?
        let evidence: String
    }

    typealias ExecuteHandler = @Sendable (Command) async throws -> ResultPayload

    let spec = V4ToolSpec(
        toolName: "apple.music.control",
        displayName: "控制音乐",
        summary: "控制本机 Music 播放、暂停、继续与切歌，并返回播放证据。",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(
            fields: [
                V4ToolInputField(name: "command", kind: .string, summary: "原始命令"),
                V4ToolInputField(name: "query", kind: .string, isRequired: false, summary: "播放目标")
            ]
        ),
        requiresPermission: true,
        permissionScope: .appleNativeApps,
        isConcurrencySafe: false,
        mutatesUserData: true,
        supportsStreamingResults: false
    )

    private let executeHandler: ExecuteHandler
    private let errorCatalog = V4ToolErrorCatalog()

    init(executeHandler: ExecuteHandler? = nil) {
        self.executeHandler = executeHandler ?? Self.liveExecuteHandler()
    }

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        let command = arguments.string(for: "command")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`command` 不能为空。",
                messageForDebug: "music command empty"
            )
        }
        return nil
    }

    func execute(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let resolved = resolveCommand(arguments: arguments)
        let commandText = arguments.string(for: "command") ?? ""
        if magicianIsDryRunCommand(commandText) {
            return V4ToolExecutionOutput(
                outputText: "演练完成：将执行音乐控制（\(resolved.action.rawValue)）。",
                evidenceSummary: "apple.music.control dry_run=true",
                rawPayload: .object(
                    [
                        "action": .string(resolved.action.rawValue),
                        "query": resolved.query.map(V4ToolValue.string) ?? .null,
                        "dryRun": .boolean(true),
                        "summary": .string("演练完成：将执行音乐控制（\(resolved.action.rawValue)）。")
                    ]
                )
            )
        }
        let result = try await executeHandler(resolved)
        let outputText: String
        if result.action == .open {
            outputText = "已打开 Music，尚未执行播放。"
        } else if let track = result.track {
            if let artist = result.artist, !artist.isEmpty {
                outputText = "已开始播放：\(artist) - \(track)"
            } else {
                outputText = "已开始播放：\(track)"
            }
        } else {
            switch result.action {
            case .open:
                outputText = "已打开 Music，尚未执行播放。"
            case .pause:
                outputText = "已暂停播放"
            case .resume:
                outputText = "已继续播放"
            case .next:
                outputText = "已切到下一首"
            case .previous:
                outputText = "已切到上一首"
            case .play:
                outputText = "已开始播放"
            }
        }

        return V4ToolExecutionOutput(
            outputText: outputText,
            evidenceSummary: "apple.music.control action=\(result.action.rawValue) state=\(result.state)",
            rawPayload: .object(
                [
                    "action": .string(result.action.rawValue),
                    "state": .string(result.state),
                    "track": result.track.map(V4ToolValue.string) ?? .null,
                    "artist": result.artist.map(V4ToolValue.string) ?? .null,
                    "evidence": .string(result.evidence),
                    "summary": .string(outputText)
                ]
            )
        )
    }

    private func resolveCommand(arguments: V4ToolArguments) -> Command {
        let explicitQuery = arguments.string(for: "query")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = arguments.string(for: "command") ?? ""
        let lowered = command.lowercased()

        if containsAny(lowered, keywords: ["暂停", "pause", "停止播放", "停一下"]) {
            return Command(action: .pause, query: nil)
        }
        if containsAny(lowered, keywords: ["继续", "恢复", "resume", "继续播放"]) {
            return Command(action: .resume, query: nil)
        }
        if containsAny(lowered, keywords: ["下一首", "下一曲", "next", "切歌"]) {
            return Command(action: .next, query: nil)
        }
        if containsAny(lowered, keywords: ["上一首", "上一曲", "previous", "prev"]) {
            return Command(action: .previous, query: nil)
        }
        if containsAny(lowered, keywords: ["打开音乐", "打开 music", "启动音乐", "启动 music", "播放音乐", "打开播放器", "启动播放器"]) {
            return Command(action: .open, query: nil)
        }
        if let explicitQuery, !explicitQuery.isEmpty {
            return Command(action: .play, query: explicitQuery)
        }
        let inferredQuery = magicianMusicSearchQueries(from: command).first
        if let inferredQuery, isGenericPlaybackQuery(inferredQuery) {
            return Command(action: .play, query: nil)
        }
        return Command(action: .play, query: inferredQuery)
    }

    private func containsAny(_ value: String, keywords: [String]) -> Bool {
        keywords.contains { value.contains($0) }
    }

    private func isGenericPlaybackQuery(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [
            "音乐", "music", "歌曲", "歌", "打开音乐", "播放音乐", "打开播放器", "启动音乐", "启动播放器"
        ].contains(normalized)
    }

    private static func liveExecuteHandler() -> ExecuteHandler {
        { command in
            guard MagicianMusicCapability.musicAppAvailable else {
                throw V4ToolErrorCatalog().bridgeNotReady(
                    toolID: "apple.music.control",
                    userMessage: "Music 不可用，请先打开音乐应用。",
                    debugMessage: "music app unavailable",
                    recoverAction: "open_music_app"
                )
            }

            let warmup = await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false, timeoutSeconds: 12) + [
                    "set ready to false",
                    "repeat with idx from 1 to 6",
                    "try",
                    "set _count to (count of tracks of library playlist 1)",
                    "set ready to true",
                    "exit repeat",
                    "on error",
                    "delay 0.08",
                    "end try",
                    "end repeat",
                    "if ready then return \"library_ready\"",
                    "return \"library_pending\"",
                    "end tell"
                ],
                arguments: [],
                timeoutSeconds: 7
            )
            guard warmup.exitCode == 0 else {
                let recoverAction = magicianLooksLikeAutomationPermissionDenied(warmup.detail)
                    ? "open_music_automation_permission"
                    : "open_music_app"
                throw V4ToolErrorCatalog().executionFailure(
                    toolID: "apple.music.control",
                    userMessage: "Music 启动失败，请确认应用可正常打开后再试。",
                    debugMessage: warmup.detail,
                    recoverAction: recoverAction
                )
            }

            let process = await runLiveCommand(command)
            guard process.exitCode == 0 else {
                let recoverAction = magicianLooksLikeAutomationPermissionDenied(process.detail)
                    ? "open_music_automation_permission"
                    : "open_music_app"
                throw V4ToolErrorCatalog().executionFailure(
                    toolID: "apple.music.control",
                    userMessage: "音乐控制失败，请确认 Music 已启动且曲库可访问后再试。",
                    debugMessage: process.detail,
                    recoverAction: recoverAction
                )
            }

            let output = process.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if command.action == .open {
                return ResultPayload(
                    action: .open,
                    state: "open",
                    track: nil,
                    artist: nil,
                    evidence: output.isEmpty ? "state=open" : output
                )
            }
            if command.action == .play, let query = command.query, !query.isEmpty {
                if output.hasPrefix("search_opened|") {
                    return ResultPayload(
                        action: .open,
                        state: "open_search",
                        track: nil,
                        artist: nil,
                        evidence: output
                    )
                }
                if output == "track_not_found" {
                    throw V4ToolErrorCatalog().executionFailure(
                        toolID: "apple.music.control",
                        userMessage: "未在 Music 搜索里找到这首歌，请确认歌名后再试。",
                        debugMessage: "no matched track for query: \(query)",
                        recoverAction: "open_music_app",
                        isRetryable: false
                    )
                }
                if !magicianMusicEvidenceMatchesQuery(output: output, query: query) {
                    throw V4ToolErrorCatalog().missingEvidence(
                        toolID: "apple.music.control",
                        requirement: .summary,
                        debugMessage: "music evidence mismatch; query=\(query); output=\(output)"
                    )
                }
            }

            let parsed = parseEvidence(output)
            return ResultPayload(
                action: command.action,
                state: parsed.state ?? command.action.rawValue,
                track: parsed.track,
                artist: parsed.artist,
                evidence: output.isEmpty ? "state=\(command.action.rawValue)" : output
            )
        }
    }

    private static func runLiveCommand(_ command: Command) async -> MagicianProcessResult {
        switch command.action {
        case .open:
            return await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines() + [
                    "return \"state=open\"",
                    "end tell"
                ],
                arguments: []
            )

        case .play:
            if let query = command.query, !query.isEmpty {
                for item in magicianMusicSearchQueries(from: query) {
                    let result = await runLibrarySearchAndPlay(keyword: item)
                    if result.exitCode == 0, result.stdout.hasPrefix("track=") {
                        return result
                    }
                }

                let uiAssist = await runUISearchAssist(query: query)
                if uiAssist.exitCode == 0 {
                    let trimmed = uiAssist.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("track=") {
                        return uiAssist
                    }
                    return MagicianProcessResult(
                        exitCode: 0,
                        stdout: "search_opened|query=\(query)|state=open_search",
                        stderr: ""
                    )
                }
                return MagicianProcessResult(
                    exitCode: 0,
                    stdout: "search_opened|query=\(query)|state=open_search",
                    stderr: uiAssist.detail
                )
            }
            return await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines() + [
                    "play",
                    "return \"state=play\"",
                    "end tell"
                ],
                arguments: []
            )

        case .pause:
            return await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false) + [
                    "pause",
                    "return \"state=pause\"",
                    "end tell"
                ],
                arguments: []
            )

        case .resume:
            return await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false) + [
                    "play",
                    "return \"state=resume\"",
                    "end tell"
                ],
                arguments: []
            )

        case .next:
            return await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false) + [
                    "next track",
                    "return \"state=next\"",
                    "end tell"
                ],
                arguments: []
            )

        case .previous:
            return await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false) + [
                    "previous track",
                    "return \"state=previous\"",
                    "end tell"
                ],
                arguments: []
            )
        }
    }

    private static func runLibrarySearchAndPlay(keyword: String) async -> MagicianProcessResult {
        await runOsaScript(
            lines: [
                "on run argv",
                "set keywordText to item 1 of argv",
                "tell application \"Music\"",
            ] + magicianEnsureApplicationReadyAppleScriptLines() + [
                "set matchedTracks to (search library playlist 1 for keywordText only songs)",
                "if (count of matchedTracks) is 0 then return \"track_not_found\"",
                "set targetTrack to item 1 of matchedTracks",
                "play targetTrack",
                "delay 0.8",
                "set nowTrack to current track",
                "return \"track=\" & (name of nowTrack) & \"|artist=\" & (artist of nowTrack) & \"|state=play|strategy=library_search\"",
                "end tell",
                "end run"
            ],
            arguments: [keyword]
        )
    }

    private static func runUISearchAssist(query: String) async -> MagicianProcessResult {
        await runOsaScript(
            lines: [
                "on run argv",
                "set keywordText to item 1 of argv",
                "tell application \"Music\"",
                "activate",
                "end tell",
                "delay 0.2",
                "try",
                "tell application \"System Events\"",
                "if not (UI elements enabled) then error \"ui scripting disabled\"",
                "tell process \"Music\"",
                "set frontmost to true",
                "keystroke \"f\" using {command down}",
                "delay 0.15",
                "keystroke keywordText",
                "delay 0.15",
                "key code 36",
                "delay 0.7",
                "key code 125",
                "delay 0.1",
                "key code 36",
                "end tell",
                "end tell",
                "on error uiErr",
                "return \"ui_search_failed=\" & uiErr",
                "end try",
                "tell application \"Music\"",
                "delay 0.8",
                "try",
                "if player state is playing then",
                "set nowTrack to current track",
                "return \"track=\" & (name of nowTrack) & \"|artist=\" & (artist of nowTrack) & \"|state=play|strategy=ui_search\"",
                "end if",
                "end try",
                "end tell",
                "return \"ui_search_opened\"",
                "end run"
            ],
            arguments: [query],
            timeoutSeconds: 16
        )
    }

    private static func parseEvidence(_ output: String) -> (state: String?, track: String?, artist: String?) {
        var state: String?
        var track: String?
        var artist: String?
        let parts = output.split(separator: "|").map(String.init)
        for part in parts {
            if part.hasPrefix("state=") {
                state = String(part.dropFirst("state=".count))
            } else if part.hasPrefix("track=") {
                track = String(part.dropFirst("track=".count))
            } else if part.hasPrefix("artist=") {
                artist = String(part.dropFirst("artist=".count))
            }
        }
        return (state, track, artist)
    }
}

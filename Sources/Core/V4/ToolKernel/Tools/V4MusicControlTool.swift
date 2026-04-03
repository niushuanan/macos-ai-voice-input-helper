import Foundation

struct V4MusicControlTool: V4Tool {
    private struct LibraryTrackRecord: Equatable, Sendable {
        let persistentID: String
        let name: String
        let artist: String
        let album: String
    }
    struct SemanticPlayDecision: Equatable, Sendable {
        let query: String
        let intent: PlayIntent
        let confidence: Double
        let reason: String?
    }

    private struct SemanticPlayPayload: Decodable {
        let intent: String?
        let query: String?
        let confidence: Double?
        let reason: String?
    }

    private struct LibraryTrackCandidate: Equatable, Sendable {
        let track: LibraryTrackRecord
        let score: Int
    }

    private struct LibraryAlbumCandidate: Equatable, Sendable {
        let key: String
        let album: String
        let artist: String
        let trackIDs: [String]
        let score: Int
    }

    private struct RagTrackPickPayload: Decodable {
        let persistentID: String?
        let confidence: Double?
        let reason: String?
    }

    private struct RagAlbumPickPayload: Decodable {
        let albumKey: String?
        let confidence: Double?
        let reason: String?
    }

    private actor LibraryCatalogCache {
        private var tracks: [LibraryTrackRecord] = []
        private var updatedAt: Date?

        func load(maxAge: TimeInterval) -> [LibraryTrackRecord]? {
            guard
                let updatedAt,
                Date().timeIntervalSince(updatedAt) <= maxAge,
                !tracks.isEmpty
            else {
                return nil
            }
            return tracks
        }

        func save(_ tracks: [LibraryTrackRecord]) {
            self.tracks = tracks
            updatedAt = Date()
        }
    }

    enum PlayIntent: String, Equatable, Sendable {
        case auto
        case song
        case album
        case mood
    }

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
        let playIntent: PlayIntent
        let rawCommand: String
    }

    struct ResultPayload: Equatable, Sendable {
        let action: Action
        let state: String
        let track: String?
        let artist: String?
        let evidence: String
    }

    typealias ExecuteHandler = @Sendable (Command) async throws -> ResultPayload
    typealias SemanticResolver = @Sendable (String, V4ToolExecutionContext) async -> SemanticPlayDecision?

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
    private let modelSlotManager: V4ModelSlotManager?
    private let generationProvider: any TextGenerationProvider
    private let semanticResolver: SemanticResolver
    private let errorCatalog = V4ToolErrorCatalog()
    private static let libraryCatalogCache = LibraryCatalogCache()

    init(
        modelSlotManager: V4ModelSlotManager? = nil,
        generationProvider: (any TextGenerationProvider)? = nil,
        executeHandler: ExecuteHandler? = nil,
        semanticResolver: SemanticResolver? = nil
    ) {
        let resolvedGenerationProvider = generationProvider ?? OpenAITextGenerationProvider()
        self.modelSlotManager = modelSlotManager
        self.generationProvider = resolvedGenerationProvider
        self.executeHandler = executeHandler ?? Self.liveExecuteHandler(
            modelSlotManager: modelSlotManager,
            generationProvider: resolvedGenerationProvider
        )
        if let semanticResolver {
            self.semanticResolver = semanticResolver
        } else {
            self.semanticResolver = { [modelSlotManager, generationProvider = resolvedGenerationProvider] command, context in
                await Self.liveSemanticPlayDecision(
                    command: command,
                    context: context,
                    modelSlotManager: modelSlotManager,
                    generationProvider: generationProvider
                )
            }
        }
    }

    init(executeHandler: @escaping ExecuteHandler) {
        self.init(
            modelSlotManager: nil,
            generationProvider: nil,
            executeHandler: executeHandler,
            semanticResolver: nil
        )
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
        context: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let resolved = await resolveCommand(arguments: arguments, context: context)
        let commandText = arguments.string(for: "command") ?? ""
        if magicianIsDryRunCommand(commandText) {
            return V4ToolExecutionOutput(
                outputText: "演练完成：将执行音乐控制（\(resolved.action.rawValue)）。",
                evidenceSummary: "apple.music.control dry_run=true",
                rawPayload: .object(
                    [
                        "action": .string(resolved.action.rawValue),
                        "playIntent": .string(resolved.playIntent.rawValue),
                        "query": resolved.query.map(V4ToolValue.string) ?? .null,
                        "dryRun": .boolean(true),
                        "summary": .string("演练完成：将执行音乐控制（\(resolved.action.rawValue)）。")
                    ]
                )
            )
        }
        let result = try await executeHandler(resolved)
        let resolvedState = normalizedMusicState(result.state, action: result.action)
        let outputText: String
        if result.action == .open, resolvedState == "open_search" {
            outputText = "已打开 Music 搜索结果，请确认播放对象。"
        } else if result.action == .open {
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

        let requestedTrack = resolved.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTrack = result.track?.trimmingCharacters(in: .whitespacesAndNewlines)
        let exactMatch = isExactTrackMatch(
            requestedTrack: requestedTrack,
            resolvedTrack: resolvedTrack,
            action: result.action
        )
        let evidenceConfidence: String = {
            if result.action == .play, let requestedTrack, !requestedTrack.isEmpty {
                return exactMatch ? "high" : "low"
            }
            return "medium"
        }()
        let enrichedEvidence = enrichedEvidenceSummary(
            baseEvidence: composedEvidenceSummary(
                action: result.action,
                state: resolvedState,
                track: result.track,
                artist: result.artist,
                rawEvidence: result.evidence
            ),
            requestedTrack: requestedTrack,
            resolvedTrack: resolvedTrack,
            exactMatch: exactMatch,
            playbackState: resolvedState,
            evidenceConfidence: evidenceConfidence
        )

        return V4ToolExecutionOutput(
            outputText: outputText,
            evidenceSummary: enrichedEvidence,
            rawPayload: .object(
                [
                    "action": .string(result.action.rawValue),
                    "state": .string(resolvedState),
                    "playIntent": .string(resolved.playIntent.rawValue),
                    "requestedTrack": requestedTrack.map(V4ToolValue.string) ?? .null,
                    "track": result.track.map(V4ToolValue.string) ?? .null,
                    "resolvedTrack": resolvedTrack.map(V4ToolValue.string) ?? .null,
                    "exactMatch": .boolean(exactMatch),
                    "playbackState": .string(resolvedState),
                    "evidenceConfidence": .string(evidenceConfidence),
                    "artist": result.artist.map(V4ToolValue.string) ?? .null,
                    "evidence": .string(result.evidence),
                    "summary": .string(outputText)
                ]
            )
        )
    }

    private func composedEvidenceSummary(
        action: Action,
        state: String,
        track: String?,
        artist: String?,
        rawEvidence: String
    ) -> String {
        var fields: [String] = [
            "apple.music.control",
            "action=\(action.rawValue)",
            "state=\(state)"
        ]
        if let track = track?.trimmingCharacters(in: .whitespacesAndNewlines), !track.isEmpty {
            fields.append("track=\(track)")
        }
        if let artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            fields.append("artist=\(artist)")
        }
        let trimmedRawEvidence = rawEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRawEvidence.isEmpty {
            fields.append(trimmedRawEvidence)
        }
        return fields.joined(separator: " ")
    }

    private func enrichedEvidenceSummary(
        baseEvidence: String,
        requestedTrack: String?,
        resolvedTrack: String?,
        exactMatch: Bool,
        playbackState: String,
        evidenceConfidence: String
    ) -> String {
        var lines: [String] = []
        let normalizedBase = baseEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedBase.isEmpty {
            lines.append(normalizedBase)
        }
        if let requestedTrack, !requestedTrack.isEmpty {
            lines.append("requested_track=\(requestedTrack)")
        }
        if let resolvedTrack, !resolvedTrack.isEmpty {
            lines.append("resolved_track=\(resolvedTrack)")
        }
        lines.append("exact_match=\(exactMatch ? "true" : "false")")
        lines.append("playback_state=\(playbackState)")
        lines.append("evidence_confidence=\(evidenceConfidence)")
        return lines.joined(separator: "|")
    }

    private func isExactTrackMatch(
        requestedTrack: String?,
        resolvedTrack: String?,
        action: Action
    ) -> Bool {
        guard action == .play else {
            return true
        }
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

    private func normalizedMusicState(_ raw: String, action: Action) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        switch action {
        case .open:
            return "open"
        case .play:
            return "play"
        case .pause:
            return "pause"
        case .resume:
            return "resume"
        case .next:
            return "next"
        case .previous:
            return "previous"
        }
    }

    private func resolveCommand(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async -> Command {
        let explicitQuery = arguments.string(for: "query")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = arguments.string(for: "command") ?? ""
        let lowered = command.lowercased()

        if containsAny(lowered, keywords: ["暂停", "pause", "停止播放", "停一下"]) {
            return Command(action: .pause, query: nil, playIntent: .auto, rawCommand: command)
        }
        if containsAny(lowered, keywords: ["继续", "恢复", "resume", "继续播放"]) {
            return Command(action: .resume, query: nil, playIntent: .auto, rawCommand: command)
        }
        if containsAny(lowered, keywords: ["下一首", "下一曲", "next", "切歌"]) {
            return Command(action: .next, query: nil, playIntent: .auto, rawCommand: command)
        }
        if containsAny(lowered, keywords: ["上一首", "上一曲", "previous", "prev"]) {
            return Command(action: .previous, query: nil, playIntent: .auto, rawCommand: command)
        }
        if containsAny(lowered, keywords: ["打开音乐", "打开 music", "启动音乐", "启动 music", "播放音乐", "打开播放器", "启动播放器"]) {
            return Command(action: .open, query: nil, playIntent: .auto, rawCommand: command)
        }
        if let moodQuery = inferredMoodQuery(from: lowered) {
            return Command(action: .play, query: moodQuery, playIntent: .mood, rawCommand: command)
        }
        let playIntent = inferredPlayIntent(from: lowered)
        if let explicitQuery, !explicitQuery.isEmpty {
            return Command(action: .play, query: explicitQuery, playIntent: playIntent, rawCommand: command)
        }

        let inferredQuery = magicianMusicSearchQueries(from: command).first
        if shouldUseSemanticIntentResolver(loweredCommand: lowered, inferredQuery: inferredQuery) {
            if let semanticDecision = await semanticResolver(command, context) {
                return Command(
                    action: .play,
                    query: semanticDecision.query,
                    playIntent: semanticDecision.intent,
                    rawCommand: command
                )
            }
        }

        if let inferredQuery, isGenericPlaybackQuery(inferredQuery) {
            return Command(action: .play, query: nil, playIntent: .auto, rawCommand: command)
        }
        return Command(action: .play, query: inferredQuery, playIntent: playIntent, rawCommand: command)
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

    private func shouldUseSemanticIntentResolver(loweredCommand: String, inferredQuery: String?) -> Bool {
        if containsAny(loweredCommand, keywords: ["《", "》", "“", "”", "\"", "专辑", "album"]) {
            return false
        }
        if containsAny(
            loweredCommand,
            keywords: [
                "我很", "我现在", "心情", "悲伤", "难过", "失恋", "压力", "焦虑", "孤独", "低落",
                "开心", "快乐", "放松", "治愈", "燃", "热血",
                "来首歌", "放首歌", "来点歌", "放点歌", "推荐", "随便", "随机",
                "适合", "场景", "通勤", "学习", "工作", "夜晚", "睡前", "开车", "跑步",
                "sad", "happy", "mood", "vibe", "focus", "study", "chill"
            ]
        ) {
            return true
        }

        guard let inferredQuery else {
            return true
        }
        let normalized = inferredQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || isGenericPlaybackQuery(normalized) {
            return true
        }
        let termCount = normalized.split(whereSeparator: \.isWhitespace).count
        let looksLikeDirectTitle = normalized.count <= 10 && termCount <= 2
        return !looksLikeDirectTitle
    }

    private func inferredPlayIntent(from loweredCommand: String) -> PlayIntent {
        if containsAny(loweredCommand, keywords: ["专辑", "整张", "整专", "album"]) {
            return .album
        }
        if containsAny(loweredCommand, keywords: ["一首", "这首", "歌曲", "song"]) {
            return .song
        }
        return .auto
    }

    private func inferredMoodQuery(from loweredCommand: String) -> String? {
        guard containsAny(loweredCommand, keywords: ["的歌", "歌曲", "music", "song"]) else {
            return nil
        }
        let tokens = [
            "开心", "快乐", "治愈", "放松", "轻松", "安静", "燃", "热血", "伤感",
            "sad", "happy", "calm", "relax"
        ]
        return tokens.first(where: { loweredCommand.contains($0) })
    }

    private static func isMoodDiscoveryQuery(_ query: String) -> Bool {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "开心", "快乐", "治愈", "放松", "轻松", "安静", "燃", "热血", "伤感",
            "sad", "happy", "calm", "relax"
        ].contains(normalized)
    }

    private static func moodExpansionQueries(for query: String) -> [String] {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "开心", "快乐", "happy":
            return [query, "快乐", "开心", "欢快", "upbeat"]
        case "治愈":
            return [query, "治愈", "温柔", "舒缓", "calm"]
        case "放松", "轻松", "calm", "relax":
            return [query, "放松", "轻松", "舒缓", "calm"]
        case "燃", "热血":
            return [query, "热血", "燃", "激情", "rock"]
        case "伤感", "sad":
            return [query, "伤感", "sad", "抒情", "慢歌"]
        default:
            let separators = CharacterSet(charactersIn: ",，、/| ")
            let terms = query
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Array(Set([query] + terms))
        }
    }

    private static func ambiguityProbeFlags(from output: String) -> (songExact: Bool, albumExact: Bool) {
        let parts = output.split(separator: "|").map(String.init)
        var songExact = false
        var albumExact = false
        for part in parts {
            if part == "song_exact=true" {
                songExact = true
            } else if part == "album_exact=true" {
                albumExact = true
            }
        }
        return (songExact, albumExact)
    }

    private static func liveSemanticPlayDecision(
        command: String,
        context: V4ToolExecutionContext,
        modelSlotManager: V4ModelSlotManager?,
        generationProvider: any TextGenerationProvider
    ) async -> SemanticPlayDecision? {
        guard let configuration = await semanticModelConfiguration(
            context: context,
            modelSlotManager: modelSlotManager
        ) else {
            return nil
        }
        let apiKey = await semanticModelAPIKey(context: context, modelSlotManager: modelSlotManager) ?? ""
        guard !configuration.providerType.requiresAPIKey || !apiKey.isEmpty else {
            return nil
        }

        let systemPrompt = """
        你是 PulseType 的音乐语义解析器。请把自然语言音乐请求解析成 JSON。
        只输出 JSON，不要解释。JSON 字段：
        intent: song | album | mood | scene | vibe | artist | none
        query: 可用于 Music 资料库搜索的短查询词
        confidence: 0~1
        reason: 简短原因
        规则：
        1) 明确歌名用 song；明确专辑名用 album。
        2) 情绪/场景/模糊意图请求（如“我很悲伤，放首歌”“通勤路上来点歌”）用 mood/scene/vibe/artist，query 输出 1~3 个可检索短词。
        3) 无法判断时 intent=none，query 为空字符串。
        """
        let userPrompt = "用户请求：\(command)"

        do {
            let generation = try await generationProvider.generateText(
                request: TextGenerationRequest(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    temperature: 0.1,
                    maxOutputTokens: 180
                ),
                configuration: configuration,
                apiKey: apiKey
            )
            guard
                let payload: SemanticPlayPayload = decodeLLMJSONPayload(from: generation.outputText),
                let rawIntent = payload.intent?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                let intent = normalizedSemanticIntent(rawIntent),
                intent != .auto,
                let query = payload.query?.trimmingCharacters(in: .whitespacesAndNewlines),
                !query.isEmpty
            else {
                return nil
            }
            let confidence = payload.confidence ?? 0.5
            if confidence < 0.45 {
                return nil
            }
            return SemanticPlayDecision(
                query: query,
                intent: intent,
                confidence: confidence,
                reason: payload.reason
            )
        } catch {
            return nil
        }
    }

    private static func normalizedSemanticIntent(_ rawIntent: String) -> PlayIntent? {
        switch rawIntent {
        case "song":
            return .song
        case "album":
            return .album
        case "mood", "scene", "vibe", "artist":
            return .mood
        default:
            return nil
        }
    }

    private static func semanticModelConfiguration(
        context: V4ToolExecutionContext,
        modelSlotManager: V4ModelSlotManager?
    ) async -> TextGenerationProviderConfiguration? {
        do {
            let endpoint: V4ModelEndpoint
            if let resolved = context.request.modelSlots?.endpoint(for: .text) {
                endpoint = resolved
            } else if let modelSlotManager {
                endpoint = try await modelSlotManager.resolve(.text)
            } else {
                return nil
            }
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

    private static func semanticModelConfiguration(
        modelSlotManager: V4ModelSlotManager?
    ) async -> TextGenerationProviderConfiguration? {
        guard let modelSlotManager else {
            return nil
        }
        do {
            let endpoint = try await modelSlotManager.resolve(.text)
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

    private static func semanticModelAPIKey(
        context: V4ToolExecutionContext,
        modelSlotManager: V4ModelSlotManager?
    ) async -> String? {
        guard let modelSlotManager else {
            return nil
        }
        do {
            if context.request.modelSlots?.endpoint(for: .text) != nil {
                return try await modelSlotManager.loadAPIKey(for: .text)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return try await modelSlotManager.loadAPIKey(for: .text)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func semanticModelAPIKey(
        modelSlotManager: V4ModelSlotManager?
    ) async -> String? {
        guard let modelSlotManager else {
            return nil
        }
        do {
            return try await modelSlotManager.loadAPIKey(for: .text)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func decodeLLMJSONPayload<T: Decodable>(from output: String) -> T? {
        let stripped = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let firstBrace = stripped.firstIndex(of: "{"),
            let lastBrace = stripped.lastIndex(of: "}"),
            firstBrace <= lastBrace
        else {
            return nil
        }
        let jsonText = String(stripped[firstBrace ... lastBrace])
        guard let data = jsonText.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func liveExecuteHandler(
        modelSlotManager: V4ModelSlotManager?,
        generationProvider: any TextGenerationProvider
    ) -> ExecuteHandler {
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

            let process = await runLiveCommand(
                command,
                modelSlotManager: modelSlotManager,
                generationProvider: generationProvider
            )
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
            var normalizedOutput = output
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
                    let message = if command.playIntent == .album {
                        "未在 Music 搜索里找到该专辑，请确认专辑名后再试。"
                    } else {
                        "未在 Music 搜索里找到这首歌，请确认歌名后再试。"
                    }
                    throw V4ToolErrorCatalog().executionFailure(
                        toolID: "apple.music.control",
                        userMessage: message,
                        debugMessage: "no matched track for query: \(query)",
                        recoverAction: "open_music_app",
                        isRetryable: false
                    )
                }
                let matchesEvidence: Bool = {
                    if command.playIntent == .album {
                        return albumEvidenceMatchesQuery(output: output, query: query)
                    }
                    if Self.isMoodDiscoveryQuery(query) {
                        return true
                    }
                    return magicianMusicEvidenceMatchesQuery(output: output, query: query)
                }()
                if !matchesEvidence {
                    normalizedOutput = Self.normalizedPlaybackEvidenceForMismatch(
                        rawOutput: output,
                        query: query,
                        action: command.action
                    )
                }
            }

            let parsed = parseEvidence(normalizedOutput)
            return ResultPayload(
                action: command.action,
                state: parsed.state ?? command.action.rawValue,
                track: parsed.track,
                artist: parsed.artist,
                evidence: normalizedOutput.isEmpty ? "state=\(command.action.rawValue)" : normalizedOutput
            )
        }
    }

    private static func runLiveCommand(
        _ command: Command,
        modelSlotManager: V4ModelSlotManager?,
        generationProvider: any TextGenerationProvider
    ) async -> MagicianProcessResult {
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
                let probe = await runSongAlbumAmbiguityProbe(query: query)
                let probeFlags: (songExact: Bool, albumExact: Bool) = {
                    guard probe.exitCode == 0 else {
                        return (false, false)
                    }
                    return Self.ambiguityProbeFlags(from: probe.stdout)
                }()

                if command.playIntent == .auto, probeFlags.songExact, probeFlags.albumExact {
                    for item in magicianMusicSearchQueries(from: query) {
                        let songFirst = await runLibrarySearchAndPlay(keyword: item)
                        if songFirst.exitCode == 0, songFirst.stdout.hasPrefix("track=") {
                            let evidence = songFirst.stdout + "|disambiguation=ambiguous_default_song"
                            return MagicianProcessResult(exitCode: 0, stdout: evidence, stderr: songFirst.stderr)
                        }
                    }
                }

                let searchOrder: [SearchKind]
                switch command.playIntent {
                case .album:
                    searchOrder = [.album, .song]
                case .song, .mood:
                    searchOrder = [.song, .album]
                case .auto:
                    if probeFlags.albumExact, !probeFlags.songExact {
                        searchOrder = [.album, .song]
                    } else {
                        searchOrder = [.song, .album]
                    }
                }

                let searchQueries: [String] = {
                    if command.playIntent == .mood {
                        return Self.moodExpansionQueries(for: query)
                    }
                    return magicianMusicSearchQueries(from: query)
                }()

                for item in searchQueries {
                    for kind in searchOrder {
                        let result: MagicianProcessResult
                        switch kind {
                        case .song:
                            result = await runLibrarySearchAndPlay(keyword: item)
                        case .album:
                            result = await runLibraryAlbumSearchAndPlay(keyword: item)
                        }
                        if result.exitCode == 0, result.stdout.hasPrefix("track=") {
                            return result
                        }
                    }
                }

                if let ragPick = await runLibraryRAGSelectionAndPlay(
                    query: query,
                    rawCommand: command.rawCommand,
                    playIntent: command.playIntent,
                    modelSlotManager: modelSlotManager,
                    generationProvider: generationProvider
                ) {
                    return ragPick
                }

                if command.playIntent == .mood, let moodFallback = await runFallbackLibraryOrderedPlay() {
                    return moodFallback
                }

                return MagicianProcessResult(exitCode: 0, stdout: "track_not_found", stderr: "library_only_mode")
            }
            return await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false)
                    + libraryOrderedPlaybackSetupAppleScriptLines(anchorToLibraryQueue: true)
                    + [
                    "play",
                    "return \"state=play|queue_mode=library_order\"",
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
                ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false)
                    + libraryOrderedPlaybackSetupAppleScriptLines()
                    + [
                    "play",
                    "return \"state=resume|queue_mode=library_order\"",
                    "end tell"
                ],
                arguments: []
            )

        case .next:
            return await runLibraryOrderedStep(direction: "next")

        case .previous:
            return await runLibraryOrderedStep(direction: "previous")
        }
    }

    private static func runLibraryOrderedStep(direction: String) async -> MagicianProcessResult {
        await runOsaScript(
            lines: [
                "on run argv",
                "set directionText to item 1 of argv",
                "tell application \"Music\"",
            ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false)
                + libraryOrderedPlaybackSetupAppleScriptLines()
                + [
                "set libraryTracks to tracks of library playlist 1",
                "set totalCount to count of libraryTracks",
                "if totalCount is 0 then error \"library empty\"",
                "set targetIndex to 1",
                "try",
                "set nowTrack to current track",
                "set nowTrackID to (persistent ID of nowTrack) as string",
                "repeat with idx from 1 to totalCount",
                "set candidateTrack to item idx of libraryTracks",
                "try",
                "set candidateID to (persistent ID of candidateTrack) as string",
                "if candidateID is nowTrackID then",
                "if directionText is \"next\" then",
                "set targetIndex to idx + 1",
                "if targetIndex > totalCount then set targetIndex to 1",
                "else",
                "set targetIndex to idx - 1",
                "if targetIndex < 1 then set targetIndex to totalCount",
                "end if",
                "exit repeat",
                "end if",
                "end try",
                "end repeat",
                "on error",
                "if directionText is \"next\" then",
                "set targetIndex to 1",
                "else",
                "set targetIndex to totalCount",
                "end if",
                "end try",
                "set targetTrack to item targetIndex of libraryTracks",
                "play targetTrack",
                "delay 0.5",
                "set nowTrack to current track",
                "if directionText is \"next\" then",
                "set resolvedState to \"next\"",
                "else",
                "set resolvedState to \"previous\"",
                "end if",
                "return \"track=\" & (name of nowTrack) & \"|artist=\" & (artist of nowTrack) & \"|state=\" & resolvedState & \"|strategy=library_order|queue_mode=library_order\"",
                "end tell",
                "end run"
            ],
            arguments: [direction]
        )
    }

    private static func runLibrarySearchAndPlay(keyword: String) async -> MagicianProcessResult {
        await runOsaScript(
            lines: [
                "on run argv",
                "set keywordText to item 1 of argv",
                "tell application \"Music\"",
            ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false)
                + libraryOrderedPlaybackSetupAppleScriptLines()
                + [
                "set matchedTracks to (search library playlist 1 for keywordText only songs)",
                "if (count of matchedTracks) is 0 then return \"track_not_found\"",
                "set targetTrack to item 1 of matchedTracks",
                "play targetTrack",
                "delay 0.8",
                "set nowTrack to current track",
                "return \"track=\" & (name of nowTrack) & \"|artist=\" & (artist of nowTrack) & \"|album=\" & (album of nowTrack) & \"|state=play|strategy=library_song|queue_mode=library_order\"",
                "end tell",
                "end run"
            ],
            arguments: [keyword]
        )
    }

    private static func runLibraryAlbumSearchAndPlay(keyword: String) async -> MagicianProcessResult {
        await runOsaScript(
            lines: [
                "on run argv",
                "set keywordText to item 1 of argv",
                "tell application \"Music\"",
            ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false)
                + libraryOrderedPlaybackSetupAppleScriptLines()
                + [
                "set matchedTracks to (search library playlist 1 for keywordText only albums)",
                "if (count of matchedTracks) is 0 then return \"album_not_found\"",
                "set targetTrack to item 1 of matchedTracks",
                "play targetTrack",
                "delay 0.8",
                "set nowTrack to current track",
                "return \"track=\" & (name of nowTrack) & \"|artist=\" & (artist of nowTrack) & \"|album=\" & (album of nowTrack) & \"|state=play|strategy=library_album_order|queue_mode=library_order\"",
                "end tell",
                "end run"
            ],
            arguments: [keyword]
        )
    }

    private static func runSongAlbumAmbiguityProbe(query: String) async -> MagicianProcessResult {
        await runOsaScript(
            lines: [
                "on run argv",
                "set keywordText to item 1 of argv",
                "set hasSong to false",
                "set hasAlbum to false",
                "tell application \"Music\"",
            ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false) + [
                "set songHits to (search library playlist 1 for keywordText only songs)",
                "repeat with t in songHits",
                "if (name of t) is keywordText then",
                "set hasSong to true",
                "exit repeat",
                "end if",
                "end repeat",
                "set albumHits to (search library playlist 1 for keywordText only albums)",
                "repeat with t in albumHits",
                "if (album of t) is keywordText then",
                "set hasAlbum to true",
                "exit repeat",
                "end if",
                "end repeat",
                "end tell",
                "return \"song_exact=\" & (hasSong as string) & \"|album_exact=\" & (hasAlbum as string)"
            ],
            arguments: [query]
        )
    }

    private enum SearchKind {
        case song
        case album
    }

    private static func runLibraryRAGSelectionAndPlay(
        query: String,
        rawCommand: String,
        playIntent: PlayIntent,
        modelSlotManager: V4ModelSlotManager?,
        generationProvider: any TextGenerationProvider
    ) async -> MagicianProcessResult? {
        let tracks = await loadLibraryCatalog()
        guard !tracks.isEmpty else {
            return nil
        }

        let pick: LibraryTrackRecord?
        if playIntent == .album {
            var albumCandidates = retrieveAlbumCandidates(query: query, tracks: tracks, limit: tracks.count)
            if albumCandidates.isEmpty {
                albumCandidates = retrieveAllAlbumCandidates(tracks: tracks)
            }
            guard !albumCandidates.isEmpty else {
                return nil
            }
            let pickedAlbum = await selectAlbumWithRAG(
                query: query,
                rawCommand: rawCommand,
                candidates: albumCandidates,
                modelSlotManager: modelSlotManager,
                generationProvider: generationProvider
            ) ?? albumCandidates.first
            pick = pickedAlbum.flatMap { randomTrackInAlbum($0, tracks: tracks) }
        } else {
            var candidates = retrieveLibraryCandidates(
                query: query,
                rawCommand: rawCommand,
                playIntent: playIntent,
                tracks: tracks,
                limit: tracks.count
            )
            if candidates.isEmpty {
                candidates = tracks.map { LibraryTrackCandidate(track: $0, score: 1) }
            }
            guard !candidates.isEmpty else {
                return nil
            }
            pick = await selectTrackWithRAG(
                query: query,
                rawCommand: rawCommand,
                playIntent: playIntent,
                candidates: candidates,
                modelSlotManager: modelSlotManager,
                generationProvider: generationProvider
            ) ?? localFallbackTrack(
                query: query,
                playIntent: playIntent,
                tracks: tracks,
                candidates: candidates
            )
        }
        guard let pick else {
            return nil
        }

        let playResult = await playTrackByPersistentID(pick.persistentID)
        guard playResult.exitCode == 0, playResult.stdout.hasPrefix("track=") else {
            return nil
        }
        let evidence = playResult.stdout + "|strategy=library_rag"
        return MagicianProcessResult(exitCode: 0, stdout: evidence, stderr: playResult.stderr)
    }

    private static func loadLibraryCatalog() async -> [LibraryTrackRecord] {
        if let cached = await libraryCatalogCache.load(maxAge: 12) {
            return cached
        }
        let catalogResult = await fetchLibraryCatalog()
        guard catalogResult.exitCode == 0 else {
            return []
        }
        let tracks = parseLibraryCatalog(catalogResult.stdout)
        guard !tracks.isEmpty else {
            return []
        }
        await libraryCatalogCache.save(tracks)
        return tracks
    }

    private static func retrieveLibraryCandidates(
        query: String,
        rawCommand: String,
        playIntent: PlayIntent,
        tracks: [LibraryTrackRecord],
        limit: Int
    ) -> [LibraryTrackCandidate] {
        let searchTexts = magicianMusicSearchQueries(from: query)
        let normalizedQueries = searchTexts
            .map(normalizedMusicMatchText)
            .filter { !$0.isEmpty }
        let rawNormalized = normalizedMusicMatchText(rawCommand)
        let isAlbumIntent = playIntent == .album || rawCommand.lowercased().contains("专辑")

        var scored: [LibraryTrackCandidate] = []
        scored.reserveCapacity(min(tracks.count, limit * 3))

        for track in tracks {
            let normalizedName = normalizedMusicMatchText(track.name)
            let normalizedArtist = normalizedMusicMatchText(track.artist)
            let normalizedAlbum = normalizedMusicMatchText(track.album)
            let combined = normalizedName + normalizedArtist + normalizedAlbum
            guard !combined.isEmpty else {
                continue
            }

            var bestScore = 0
            for nq in normalizedQueries {
                var score = 0
                if nq == normalizedName {
                    score += 140
                } else if !nq.isEmpty, normalizedName.contains(nq) {
                    score += 105
                }
                if isAlbumIntent {
                    if nq == normalizedAlbum {
                        score += 135
                    } else if !nq.isEmpty, normalizedAlbum.contains(nq) {
                        score += 100
                    }
                } else {
                    if !nq.isEmpty, normalizedAlbum.contains(nq) {
                        score += 45
                    }
                }
                if !nq.isEmpty, normalizedArtist.contains(nq) {
                    score += 35
                }
                let parts = queryParts(from: nq)
                if !parts.isEmpty {
                    let hitCount = parts.reduce(0) { $0 + (combined.contains($1) ? 1 : 0) }
                    score += hitCount * 14
                }
                bestScore = max(bestScore, score)
            }

            if bestScore == 0, !rawNormalized.isEmpty {
                if combined.contains(rawNormalized) {
                    bestScore = 80
                }
            }

            if bestScore > 0 {
                scored.append(LibraryTrackCandidate(track: track, score: bestScore))
            }
        }

        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.track.name < rhs.track.name
        }
        return Array(sorted.prefix(limit))
    }

    private static func retrieveAlbumCandidates(
        query: String,
        tracks: [LibraryTrackRecord],
        limit: Int
    ) -> [LibraryAlbumCandidate] {
        let groups = groupAlbums(tracks: tracks)
        let normalizedQueries = magicianMusicSearchQueries(from: query)
            .map(normalizedMusicMatchText)
            .filter { !$0.isEmpty }
        guard !normalizedQueries.isEmpty else {
            return retrieveAllAlbumCandidates(tracks: tracks)
        }

        var results: [LibraryAlbumCandidate] = []
        for album in groups {
            let normalizedAlbum = normalizedMusicMatchText(album.album)
            let normalizedArtist = normalizedMusicMatchText(album.artist)
            var best = 0
            for q in normalizedQueries {
                var score = 0
                if normalizedAlbum == q {
                    score += 160
                } else if normalizedAlbum.contains(q) || q.contains(normalizedAlbum) {
                    score += 120
                }
                if normalizedArtist.contains(q) {
                    score += 40
                }
                let parts = queryParts(from: q)
                if !parts.isEmpty, parts.allSatisfy({ normalizedAlbum.contains($0) || normalizedArtist.contains($0) }) {
                    score += 30
                }
                best = max(best, score)
            }
            if best > 0 {
                results.append(
                    LibraryAlbumCandidate(
                        key: album.key,
                        album: album.album,
                        artist: album.artist,
                        trackIDs: album.trackIDs,
                        score: best
                    )
                )
            }
        }
        let sorted = results.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.artist != rhs.artist {
                return lhs.artist < rhs.artist
            }
            return lhs.album < rhs.album
        }
        return Array(sorted.prefix(limit))
    }

    private static func retrieveAllAlbumCandidates(tracks: [LibraryTrackRecord]) -> [LibraryAlbumCandidate] {
        groupAlbums(tracks: tracks)
            .map {
                LibraryAlbumCandidate(
                    key: $0.key,
                    album: $0.album,
                    artist: $0.artist,
                    trackIDs: $0.trackIDs,
                    score: 1
                )
            }
            .sorted { lhs, rhs in
                if lhs.artist != rhs.artist {
                    return lhs.artist < rhs.artist
                }
                return lhs.album < rhs.album
            }
    }

    private static func groupAlbums(tracks: [LibraryTrackRecord]) -> [(key: String, album: String, artist: String, trackIDs: [String])] {
        var map: [String: (album: String, artist: String, trackIDs: [String])] = [:]
        for track in tracks {
            let key = "\(normalizedMusicMatchText(track.artist))::\(normalizedMusicMatchText(track.album))"
            guard !key.hasSuffix("::"), !key.isEmpty else {
                continue
            }
            if var value = map[key] {
                value.trackIDs.append(track.persistentID)
                map[key] = value
            } else {
                map[key] = (album: track.album, artist: track.artist, trackIDs: [track.persistentID])
            }
        }
        return map.map { (key: $0.key, album: $0.value.album, artist: $0.value.artist, trackIDs: Array(Set($0.value.trackIDs))) }
    }

    private static func selectAlbumWithRAG(
        query: String,
        rawCommand: String,
        candidates: [LibraryAlbumCandidate],
        modelSlotManager: V4ModelSlotManager?,
        generationProvider: any TextGenerationProvider
    ) async -> LibraryAlbumCandidate? {
        guard
            let configuration = await semanticModelConfiguration(modelSlotManager: modelSlotManager),
            let apiKey = await semanticModelAPIKey(modelSlotManager: modelSlotManager),
            !apiKey.isEmpty || !configuration.providerType.requiresAPIKey
        else {
            return nil
        }

        let candidateList = candidates.enumerated().map { idx, item in
            "\(idx + 1). entity=album | albumKey=\(item.key) | album=\(item.album) | artist=\(item.artist) | tracks=\(item.trackIDs.count) | score=\(item.score)"
        }.joined(separator: "\n")

        let systemPrompt = """
        你是 PulseType 的专辑选择器。你会收到用户请求和一组去重后的本地专辑候选。
        只能从候选里选 1 个专辑。
        只输出 JSON，不要解释。
        JSON:
        {"albumKey":"候选中的albumKey","confidence":0~1,"reason":"一句话"}
        无法判断时：
        {"albumKey":"","confidence":0,"reason":"no-fit"}
        """
        let userPrompt = """
        用户命令：\(rawCommand)
        专辑查询词：\(query)
        候选专辑：
        \(candidateList)
        """

        do {
            let generation = try await generationProvider.generateText(
                request: TextGenerationRequest(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    temperature: 0.1,
                    maxOutputTokens: 180
                ),
                configuration: configuration,
                apiKey: apiKey
            )
            guard
                let payload: RagAlbumPickPayload = decodeLLMJSONPayload(from: generation.outputText),
                let albumKey = payload.albumKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                !albumKey.isEmpty,
                (payload.confidence ?? 0.5) >= 0.35
            else {
                return nil
            }
            return candidates.first(where: { $0.key == albumKey })
        } catch {
            return nil
        }
    }

    private static func randomTrackInAlbum(
        _ album: LibraryAlbumCandidate,
        tracks: [LibraryTrackRecord]
    ) -> LibraryTrackRecord? {
        let trackSet = Set(album.trackIDs)
        let albumTracks = tracks.filter { trackSet.contains($0.persistentID) }
        return albumTracks.first
    }

    private static func localFallbackTrack(
        query: String,
        playIntent: PlayIntent,
        tracks: [LibraryTrackRecord],
        candidates: [LibraryTrackCandidate]
    ) -> LibraryTrackRecord? {
        if playIntent == .album, let albumTrack = pickTrackFromAlbum(query: query, tracks: tracks) {
            return albumTrack
        }
        return candidates.first?.track
    }

    private static func pickTrackFromAlbum(
        query: String,
        tracks: [LibraryTrackRecord],
        exactFirst: Bool = true
    ) -> LibraryTrackRecord? {
        let queries = magicianMusicSearchQueries(from: query)
            .map(normalizedMusicMatchText)
            .filter { !$0.isEmpty }
        guard !queries.isEmpty else {
            return nil
        }

        var exact: [LibraryTrackRecord] = []
        var fuzzy: [LibraryTrackRecord] = []
        for track in tracks {
            let normalizedAlbum = normalizedMusicMatchText(track.album)
            guard !normalizedAlbum.isEmpty else {
                continue
            }
            for q in queries {
                if normalizedAlbum == q {
                    exact.append(track)
                    break
                }
                if normalizedAlbum.contains(q) || q.contains(normalizedAlbum) {
                    fuzzy.append(track)
                    break
                }
            }
        }
        if exactFirst, let pick = exact.first {
            return pick
        }
        if let pick = exact.first {
            return pick
        }
        if let pick = fuzzy.first {
            return pick
        }
        return nil
    }

    private static func selectTrackWithRAG(
        query: String,
        rawCommand: String,
        playIntent: PlayIntent,
        candidates: [LibraryTrackCandidate],
        modelSlotManager: V4ModelSlotManager?,
        generationProvider: any TextGenerationProvider
    ) async -> LibraryTrackRecord? {
        guard
            let configuration = await semanticModelConfiguration(modelSlotManager: modelSlotManager),
            let apiKey = await semanticModelAPIKey(modelSlotManager: modelSlotManager),
            !apiKey.isEmpty || !configuration.providerType.requiresAPIKey
        else {
            return nil
        }

        let candidateList = candidates.enumerated().map { idx, item in
            "\(idx + 1). id=\(item.track.persistentID) | song=\(item.track.name) | artist=\(item.track.artist) | album=\(item.track.album) | score=\(item.score)"
        }.joined(separator: "\n")

        let systemPrompt = """
        你是 PulseType 的音乐选曲器。你会收到用户请求和一组来自资料库的候选曲目。
        你必须只在候选里选 1 首最合适的歌。
        只输出 JSON，不要解释。
        JSON 格式：
        {"persistentID":"候选中的id","confidence":0~1,"reason":"一句话"}
        如果都不合适，返回：
        {"persistentID":"","confidence":0,"reason":"no-fit"}
        """
        let userPrompt = """
        用户命令：\(rawCommand)
        检索意图：\(playIntent.rawValue)
        检索词：\(query)
        候选曲目：
        \(candidateList)
        """

        do {
            let generation = try await generationProvider.generateText(
                request: TextGenerationRequest(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    temperature: 0.1,
                    maxOutputTokens: 180
                ),
                configuration: configuration,
                apiKey: apiKey
            )
            guard
                let payload: RagTrackPickPayload = decodeLLMJSONPayload(from: generation.outputText),
                let persistentID = payload.persistentID?.trimmingCharacters(in: .whitespacesAndNewlines),
                !persistentID.isEmpty,
                (payload.confidence ?? 0.5) >= 0.35
            else {
                return nil
            }
            return candidates.first(where: { $0.track.persistentID == persistentID })?.track
        } catch {
            return nil
        }
    }

    private static func fetchLibraryCatalog() async -> MagicianProcessResult {
        await runOsaScript(
            lines: [
                "tell application \"Music\"",
            ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false) + [
                "set outputText to \"\"",
                "set allTracks to tracks of library playlist 1",
                "repeat with t in allTracks",
                "try",
                "set pid to (persistent ID of t) as string",
                "set n to (name of t) as string",
                "set a to (artist of t) as string",
                "set al to (album of t) as string",
                "set outputText to outputText & pid & \"\\t\" & n & \"\\t\" & a & \"\\t\" & al & linefeed",
                "end try",
                "end repeat",
                "return outputText",
                "end tell"
            ],
            arguments: [],
            timeoutSeconds: 20
        )
    }

    private static func parseLibraryCatalog(_ text: String) -> [LibraryTrackRecord] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 4 else {
                    return nil
                }
                return LibraryTrackRecord(
                    persistentID: parts[0],
                    name: parts[1],
                    artist: parts[2],
                    album: parts[3]
                )
            }
    }

    private static func queryParts(from normalized: String) -> [String] {
        normalized
            .split(separator: "的")
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    private static func playTrackByPersistentID(_ persistentID: String) async -> MagicianProcessResult {
        await runOsaScript(
            lines: [
                "on run argv",
                "set targetPID to item 1 of argv",
                "tell application \"Music\"",
            ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false)
                + libraryOrderedPlaybackSetupAppleScriptLines()
                + [
                "set allTracks to tracks of library playlist 1",
                "repeat with t in allTracks",
                "try",
                "if ((persistent ID of t) as string) is targetPID then",
                "play t",
                "delay 0.6",
                "set nowTrack to current track",
                "return \"track=\" & (name of nowTrack) & \"|artist=\" & (artist of nowTrack) & \"|album=\" & (album of nowTrack) & \"|state=play|queue_mode=library_order\"",
                "end if",
                "end try",
                "end repeat",
                "return \"track_not_found\"",
                "end tell",
                "end run"
            ],
            arguments: [persistentID],
            timeoutSeconds: 16
        )
    }

    private static func runFallbackLibraryOrderedPlay() async -> MagicianProcessResult? {
        let result = await runOsaScript(
            lines: [
                "tell application \"Music\"",
            ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false)
                + libraryOrderedPlaybackSetupAppleScriptLines(anchorToLibraryQueue: true)
                + [
                "set allTracks to tracks of library playlist 1",
                "set totalCount to count of allTracks",
                "if totalCount is 0 then return \"track_not_found\"",
                "set targetTrack to item 1 of allTracks",
                "play targetTrack",
                "delay 0.6",
                "set nowTrack to current track",
                "return \"track=\" & (name of nowTrack) & \"|artist=\" & (artist of nowTrack) & \"|album=\" & (album of nowTrack) & \"|state=play|strategy=library_order_fallback|queue_mode=library_order\"",
                "end tell"
            ],
            arguments: [],
            timeoutSeconds: 12
        )
        guard result.exitCode == 0, result.stdout.hasPrefix("track=") else {
            return nil
        }
        return result
    }

    private static func libraryOrderedPlaybackSetupAppleScriptLines(anchorToLibraryQueue: Bool = false) -> [String] {
        var lines = [
            "try",
            "set shuffle enabled to false",
            "end try",
            "try",
            "set song repeat to off",
            "end try"
        ]
        if anchorToLibraryQueue {
            lines += [
                "try",
                "play library playlist 1",
                "delay 0.08",
                "end try"
            ]
        }
        return lines
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

    static func normalizedPlaybackEvidenceForMismatch(
        rawOutput: String,
        query: String,
        action: Action
    ) -> String {
        func normalizedNonEmpty(_ value: String?) -> String? {
            guard let value else {
                return nil
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var output = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = parseEvidence(output)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "|", with: " ")
        let fallbackState = normalizedNonEmpty(parsed.state)
            ?? action.rawValue
        let fallbackTrack = normalizedNonEmpty(parsed.track)
            ?? normalizedNonEmpty(normalizedQuery)
        let fallbackArtist = normalizedNonEmpty(parsed.artist)

        func hasKey(_ key: String) -> Bool {
            output.lowercased().contains("\(key.lowercased())=")
        }

        func appendField(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty, !hasKey(key) else {
                return
            }
            if output.isEmpty {
                output = "\(key)=\(value)"
            } else {
                output += "|\(key)=\(value)"
            }
        }

        appendField("state", fallbackState)
        appendField("track", fallbackTrack)
        appendField("artist", fallbackArtist)
        appendField("query", normalizedNonEmpty(normalizedQuery))
        appendField("evidence_confidence", "low")
        appendField("query_mismatch", "true")

        if output.isEmpty {
            output = "state=\(fallbackState)|query=\(normalizedQuery)|evidence_confidence=low|query_mismatch=true"
        }
        return output
    }

    private static func albumEvidenceMatchesQuery(output: String, query: String) -> Bool {
        let parts = output.split(separator: "|").map(String.init)
        let albumValue = parts.first(where: { $0.hasPrefix("album=") })
            .map { String($0.dropFirst("album=".count)) } ?? ""
        let normalizedAlbum = normalizedMusicMatchText(albumValue)
        guard !normalizedAlbum.isEmpty else {
            return false
        }
        let queries = magicianMusicSearchQueries(from: query)
            .map(normalizedMusicMatchText)
            .filter { !$0.isEmpty }
        for q in queries {
            if normalizedAlbum == q || normalizedAlbum.contains(q) || q.contains(normalizedAlbum) {
                return true
            }
            let parts = queryParts(from: q)
            if !parts.isEmpty, parts.allSatisfy({ normalizedAlbum.contains($0) }) {
                return true
            }
        }
        return false
    }
}

import Foundation

final class V4MDPipelineTool: V4Tool, @unchecked Sendable {
    enum NetworkPolicy: String, Codable, Sendable {
        case required
        case optional
        case off
    }

    enum StyleProfile: String, Codable, Sendable {
        case meetingNotes = "meeting_notes"
        case prd
        case weeklyReport = "weekly_report"

        var displayName: String {
            switch self {
            case .meetingNotes:
                return "会议纪要"
            case .prd:
                return "PRD"
            case .weeklyReport:
                return "周报"
            }
        }
    }

    enum ParsedBlockKind: String, Codable, Sendable {
        case text
        case table
        case metadata
    }

    struct ParsedBlock: Codable, Sendable {
        let kind: ParsedBlockKind
        let content: String
        let locationRef: String?
    }

    struct SelectedFileInput: Codable, Sendable {
        let path: String
        let name: String
        let fileType: String
        let parsedBlocks: [ParsedBlock]
    }

    struct SearchEvidence: Codable, Sendable {
        let query: String
        let title: String
        let url: String
        let snippet: String
        let timestamp: Date
        let provider: String
    }

    struct SourceAnchor: Codable, Sendable {
        let sourceType: String
        let sourceName: String
        let locationRef: String
        let excerpt: String
    }

    struct ActionItem: Codable, Sendable {
        let owner: String
        let deadline: String
        let task: String
    }

    struct MDDocumentModel: Codable, Sendable {
        let title: String
        let summary: [String]
        let keyPoints: [String]
        let actionItems: [ActionItem]
        let risks: [String]
        let todo: [String]
        let references: [String]
        let sourceAnchors: [SourceAnchor]
    }

    struct StageRecord: Codable, Sendable {
        let name: String
        let status: String
        let durationMS: Int
        let inputDigest: String
        let outputDigest: String
        let evidence: String
    }

    struct PromptEnvelope: Codable, Sendable {
        struct ContextFlags: Codable, Sendable {
            let hasVoice: Bool
            let hasSelectedText: Bool
            let hasSelectedFiles: Bool
            let sourcePriority: [String]
            let timestamp: String
        }

        struct TaskConstraints: Codable, Sendable {
            let networkPolicy: String
            let styleProfile: String
            let requiredBlocks: [String]
        }

        let voiceCommand: String
        let selectedText: String
        let selectedFiles: [SelectedFileInput]
        let contextFlags: ContextFlags
        let taskConstraints: TaskConstraints
    }

    private protocol InputSourceAdapter: Sendable {
        associatedtype Value
        func resolve(arguments: V4ToolArguments, context: V4ToolExecutionContext) -> Value
    }

    private struct VoiceAdapter: InputSourceAdapter {
        func resolve(arguments: V4ToolArguments, context: V4ToolExecutionContext) -> String? {
            arguments.string(for: "command")?.trimmedNilIfEmpty
                ?? context.request.inputText.trimmedNilIfEmpty
        }
    }

    private struct SelectionAdapter: InputSourceAdapter {
        func resolve(arguments: V4ToolArguments, context: V4ToolExecutionContext) -> String? {
            arguments.string(for: "selectedText")?.trimmedNilIfEmpty
                ?? context.request.selectionText?.trimmedNilIfEmpty
        }
    }

    private struct FileAdapter: InputSourceAdapter {
        func resolve(arguments: V4ToolArguments, context: V4ToolExecutionContext) -> [SelectedFileInput] {
            if let values = arguments["selectedFiles"]?.arrayValue {
                let parsed = parseValues(values)
                if !parsed.isEmpty {
                    return parsed
                }
            }
            return context.request.selectedFiles.map {
                SelectedFileInput(path: $0.path, name: $0.name, fileType: $0.fileType, parsedBlocks: [])
            }
        }

        private func parseValues(_ values: [V4ToolValue]) -> [SelectedFileInput] {
            values.compactMap { item in
                guard let object = item.objectValue else {
                    return nil
                }
                let path = object["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !path.isEmpty else {
                    return nil
                }
                let name = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? URL(fileURLWithPath: path).lastPathComponent
                let fileType = object["type"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? URL(fileURLWithPath: path).pathExtension.lowercased()
                return SelectedFileInput(path: path, name: name, fileType: fileType, parsedBlocks: [])
            }
        }
    }

    private struct PromptEnvelopeBuilder: Sendable {
        let voiceAdapter = VoiceAdapter()
        let selectionAdapter = SelectionAdapter()
        let fileAdapter = FileAdapter()

        func build(
            arguments: V4ToolArguments,
            context: V4ToolExecutionContext,
            styleProfile: StyleProfile,
            networkPolicy: NetworkPolicy
        ) -> PromptEnvelope {
            let command = voiceAdapter.resolve(arguments: arguments, context: context)
            let selectedText = selectionAdapter.resolve(arguments: arguments, context: context)
            let selectedFiles = fileAdapter.resolve(arguments: arguments, context: context)
            let flags = PromptEnvelope.ContextFlags(
                hasVoice: command != nil,
                hasSelectedText: selectedText != nil,
                hasSelectedFiles: !selectedFiles.isEmpty,
                sourcePriority: ["voice", "selection", "files"],
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
            let constraints = PromptEnvelope.TaskConstraints(
                networkPolicy: networkPolicy.rawValue,
                styleProfile: styleProfile.rawValue,
                requiredBlocks: ["title", "summary", "key_points", "action_items", "risks", "todo", "references", "source_anchors"]
            )
            return PromptEnvelope(
                voiceCommand: command ?? "",
                selectedText: selectedText ?? "",
                selectedFiles: selectedFiles,
                contextFlags: flags,
                taskConstraints: constraints
            )
        }
    }

    private struct EvidenceResolver: Sendable {
        func validateAnchors(
            anchors: [SourceAnchor],
            selectedText: String?,
            selectedFiles: [SelectedFileInput],
            searchEvidence: [SearchEvidence]
        ) -> [SourceAnchor] {
            let fileNameSet = Set(selectedFiles.map(\.name))
            let searchURLSet = Set(searchEvidence.map(\.url))
            let searchTitleSet = Set(searchEvidence.map(\.title))
            return anchors.filter { anchor in
                switch anchor.sourceType {
                case "selected_text":
                    return selectedText?.trimmedNilIfEmpty != nil
                case "selected_file":
                    return fileNameSet.contains(anchor.sourceName)
                case "web_search":
                    return searchURLSet.contains(anchor.locationRef) || searchTitleSet.contains(anchor.sourceName)
                default:
                    return false
                }
            }
        }
    }

    let spec = V4ToolSpec(
        toolName: "md.pipeline",
        displayName: "Markdown Pipeline",
        summary: "统一处理语音文本、选区文本与选中文件，联网生成并落盘 Markdown 文档。",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(
            fields: [
                V4ToolInputField(name: "command", kind: .string, summary: "语音命令文本"),
                V4ToolInputField(name: "selectedText", kind: .string, isRequired: false, summary: "选中文字"),
                V4ToolInputField(name: "selectedFiles", kind: .array, isRequired: false, itemKind: .object, summary: "选中文件列表"),
                V4ToolInputField(name: "styleProfile", kind: .string, isRequired: false, summary: "meeting_notes/prd/weekly_report"),
                V4ToolInputField(name: "networkPolicy", kind: .string, isRequired: false, summary: "required/optional/off")
            ],
            allowsAdditionalFields: true
        ),
        requiresPermission: true,
        requiredFeature: .markdownDocument,
        isConcurrencySafe: false,
        mutatesUserData: true,
        supportsStreamingResults: false
    )

    private let generationProvider: any TextGenerationProvider
    private let modelSlotManager: V4ModelSlotManager?
    private let modelContextOverride: V4PlannerLLM.ModelContext?
    private let session: URLSession
    private let fileManager: FileManager

    init(
        modelSlotManager: V4ModelSlotManager? = nil,
        modelContextOverride: V4PlannerLLM.ModelContext? = nil,
        generationProvider: (any TextGenerationProvider)? = nil,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.modelSlotManager = modelSlotManager
        self.modelContextOverride = modelContextOverride
        self.generationProvider = generationProvider ?? OpenAITextGenerationProvider()
        self.session = session
        self.fileManager = fileManager
    }

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        let envelope = PromptEnvelopeBuilder().build(
            arguments: arguments,
            context: context,
            styleProfile: parseStyleProfile(arguments: arguments),
            networkPolicy: parseNetworkPolicy(arguments: arguments)
        )
        if envelope.voiceCommand.isEmpty, envelope.selectedText.isEmpty, envelope.selectedFiles.isEmpty {
            return V4ToolSemanticValidationFailure(
                code: .invalidRequest,
                messageForUser: "语音命令、选中文字、选中文件不能同时为空。",
                messageForDebug: "md.pipeline no input sources"
            )
        }
        return nil
    }

    func execute(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let styleProfile = parseStyleProfile(arguments: arguments)
        let networkPolicy = parseNetworkPolicy(arguments: arguments)
        var envelope = PromptEnvelopeBuilder().build(
            arguments: arguments,
            context: context,
            styleProfile: styleProfile,
            networkPolicy: networkPolicy
        )
        let command = envelope.voiceCommand.trimmedNilIfEmpty
        let selectedText = envelope.selectedText.trimmedNilIfEmpty
        var selectedFiles = envelope.selectedFiles
        let hasVoice = envelope.contextFlags.hasVoice

        guard command != nil || selectedText != nil || !selectedFiles.isEmpty else {
            throw V4ToolErrorCatalog().semanticValidationFailure(
                toolID: spec.toolID,
                failure: V4ToolSemanticValidationFailure(
                    code: .invalidRequest,
                    messageForUser: "语音命令、选中文字、选中文件不能同时为空。",
                    messageForDebug: "md.pipeline empty prompt envelope"
                )
            )
        }

        var stageRecords: [StageRecord] = []
        let envelopeStart = Date()
        envelope = PromptEnvelope(
            voiceCommand: command ?? "",
            selectedText: selectedText ?? "",
            selectedFiles: selectedFiles,
            contextFlags: envelope.contextFlags,
            taskConstraints: envelope.taskConstraints
        )
        let envelopeText = buildPromptEnvelope(envelope: envelope)
        stageRecords.append(makeStageRecord(
            name: "intent.parse",
            startedAt: envelopeStart,
            input: command ?? "(none)",
            output: "prompt_envelope_ready",
            evidence: "input_sources=voice:\(hasVoice)|selection:\(selectedText != nil)|files:\(!selectedFiles.isEmpty)"
        ))

        let fileParseStart = Date()
        if !selectedFiles.isEmpty {
            selectedFiles = try await parseFilesViaModel(
                files: selectedFiles,
                envelopeText: envelopeText
            )
            envelope = PromptEnvelope(
                voiceCommand: envelope.voiceCommand,
                selectedText: envelope.selectedText,
                selectedFiles: selectedFiles,
                contextFlags: envelope.contextFlags,
                taskConstraints: envelope.taskConstraints
            )
        }
        stageRecords.append(makeStageRecord(
            name: "file.model_parse",
            startedAt: fileParseStart,
            input: "files=\(selectedFiles.count)",
            output: "parsed_files=\(selectedFiles.count)",
            evidence: selectedFiles.isEmpty ? "files=none" : "files_parsed=true"
        ))

        let searchStart = Date()
        let searchEvidence = try await acquireSearchEvidence(query: command ?? selectedText ?? "", policy: networkPolicy)
        if networkPolicy == .required, searchEvidence.isEmpty {
            throw V4ToolErrorCatalog().executionFailure(
                toolID: spec.toolID,
                userMessage: "生成失败：未获取到联网搜索证据。",
                debugMessage: "network evidence missing under required policy",
                recoverAction: "retry_command",
                isRetryable: false
            )
        }
        stageRecords.append(makeStageRecord(
            name: "search.acquire",
            startedAt: searchStart,
            input: command ?? "(none)",
            output: "evidence_count=\(searchEvidence.count)",
            evidence: searchEvidence.isEmpty ? "search=none" : "search_provider=wikipedia"
        ))

        let draftStart = Date()
        let documentModel = try await generateDocumentModel(
            envelopeText: envelopeText,
            selectedFiles: selectedFiles,
            searchEvidence: searchEvidence,
            styleProfile: styleProfile
        )
        stageRecords.append(makeStageRecord(
            name: "draft.generate",
            startedAt: draftStart,
            input: "profile=\(styleProfile.rawValue)",
            output: documentModel.title,
            evidence: "blocks_generated=true"
        ))

        let composeStart = Date()
        let validatedModel = validateAndRepair(model: documentModel, searchEvidence: searchEvidence, selectedText: selectedText, selectedFiles: selectedFiles)
        stageRecords.append(makeStageRecord(
            name: "blocks.compose",
            startedAt: composeStart,
            input: "model",
            output: "blocks=ok",
            evidence: "schema=validated"
        ))

        let renderStart = Date()
        let markdown = renderMarkdown(model: validatedModel, styleProfile: styleProfile)
        stageRecords.append(makeStageRecord(
            name: "markdown.render",
            startedAt: renderStart,
            input: "blocks",
            output: "chars=\(markdown.count)",
            evidence: "renderer=stable"
        ))

        let persistStart = Date()
        let fileURL = try persist(markdown: markdown, title: validatedModel.title)
        stageRecords.append(makeStageRecord(
            name: "persist.write",
            startedAt: persistStart,
            input: validatedModel.title,
            output: fileURL.path,
            evidence: "path=\(fileURL.path)"
        ))

        let memoryStart = Date()
        stageRecords.append(makeStageRecord(
            name: "memory.write",
            startedAt: memoryStart,
            input: "trace_ready",
            output: "interpretation_pending",
            evidence: "history_layers=raw_trace+plain_interpretation"
        ))

        let rawPayload = makePayload(
            fileURL: fileURL,
            markdown: markdown,
            model: validatedModel,
            stageRecords: stageRecords,
            searchEvidence: searchEvidence,
            command: command,
            selectedText: selectedText,
            selectedFiles: selectedFiles
        )

        return V4ToolExecutionOutput(
            outputText: "已生成 Markdown 文档：\(fileURL.path)",
            evidenceSummary: "md.pipeline path=\(fileURL.path);search_evidence=\(searchEvidence.count);stages=\(stageRecords.count)",
            rawPayload: rawPayload
        )
    }

    private func parseStyleProfile(arguments: V4ToolArguments) -> StyleProfile {
        if let raw = arguments.string(for: "styleProfile")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let profile = StyleProfile(rawValue: raw) {
            return profile
        }
        return .meetingNotes
    }

    private func parseNetworkPolicy(arguments: V4ToolArguments) -> NetworkPolicy {
        if let raw = arguments.string(for: "networkPolicy")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let policy = NetworkPolicy(rawValue: raw) {
            return policy
        }
        return .required
    }

    private func buildPromptEnvelope(envelope: PromptEnvelope) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if
            let data = try? encoder.encode(envelope),
            let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        return """
        {
          "voice_command":"\(envelope.voiceCommand)",
          "selected_text":"\(envelope.selectedText)",
          "selected_files_count":\(envelope.selectedFiles.count)
        }
        """
    }

    private func parseFilesViaModel(
        files: [SelectedFileInput],
        envelopeText: String
    ) async throws -> [SelectedFileInput] {
        guard let modelContext = try await semanticModelContext() else {
            throw V4ToolErrorCatalog().executionFailure(
                toolID: spec.toolID,
                userMessage: "文件解析失败：模型不可用。",
                debugMessage: "model context unavailable for file.model_parse",
                recoverAction: "check_model_configuration",
                isRetryable: false
            )
        }

        return try await withThrowingTaskGroup(of: SelectedFileInput.self) { group in
            for file in files {
                group.addTask {
                    let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
                    let prefix = data.prefix(64 * 1024)
                    let base64 = prefix.base64EncodedString()
                    let prompt = """
                    你要解析一个文件并提取可用于 Markdown 的结构化块。
                    仅返回 JSON array，不要解释。
                    每个元素格式：{"kind":"text|table|metadata","content":"...","location_ref":"..."}

                    文件名：\(file.name)
                    文件类型：\(file.fileType)
                    文件内容（base64前64KB）：\(base64)

                    任务上下文：
                    \(envelopeText)
                    """
                    let generated = try await self.generationProvider.generateText(
                        request: TextGenerationRequest(
                            systemPrompt: "你是文件解析器。",
                            userPrompt: prompt,
                            temperature: 0,
                            maxOutputTokens: 900
                        ),
                        configuration: modelContext.configuration,
                        apiKey: modelContext.apiKey
                    )
                    let blocks = self.decodeParsedBlocks(from: generated.outputText)
                    return SelectedFileInput(
                        path: file.path,
                        name: file.name,
                        fileType: file.fileType,
                        parsedBlocks: blocks
                    )
                }
            }

            var parsed: [SelectedFileInput] = []
            for try await file in group {
                parsed.append(file)
            }
            return parsed.sorted { $0.path < $1.path }
        }
    }

    private func decodeParsedBlocks(from raw: String) -> [ParsedBlock] {
        let candidate = extractJSONCandidate(from: raw)
        guard
            let data = candidate.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([DecodedParsedBlock].self, from: data)
        else {
            return [ParsedBlock(kind: .metadata, content: "模型未返回可解析文件块。", locationRef: nil)]
        }

        return decoded.map {
            ParsedBlock(
                kind: ParsedBlockKind(rawValue: $0.kind) ?? .text,
                content: $0.content,
                locationRef: $0.locationRef
            )
        }
    }

    private func acquireSearchEvidence(query: String, policy: NetworkPolicy) async throws -> [SearchEvidence] {
        guard policy != .off else {
            return []
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        var components = URLComponents(string: "https://zh.wikipedia.org/w/api.php")
        components?.queryItems = [
            .init(name: "action", value: "opensearch"),
            .init(name: "search", value: trimmed),
            .init(name: "limit", value: "5"),
            .init(name: "namespace", value: "0"),
            .init(name: "format", value: "json")
        ]
        guard let url = components?.url else {
            return []
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return []
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [Any],
            json.count >= 4,
            let titles = json[1] as? [String],
            let snippets = json[2] as? [String],
            let urls = json[3] as? [String]
        else {
            return []
        }

        let timestamp = Date()
        let count = min(titles.count, snippets.count, urls.count)
        return (0..<count).map { index in
            SearchEvidence(
                query: trimmed,
                title: titles[index],
                url: urls[index],
                snippet: snippets[index],
                timestamp: timestamp,
                provider: "wikipedia_opensearch"
            )
        }
    }

    private func generateDocumentModel(
        envelopeText: String,
        selectedFiles: [SelectedFileInput],
        searchEvidence: [SearchEvidence],
        styleProfile: StyleProfile
    ) async throws -> MDDocumentModel {
        guard let modelContext = try await semanticModelContext() else {
            throw V4ToolErrorCatalog().executionFailure(
                toolID: spec.toolID,
                userMessage: "文档生成失败：模型不可用。",
                debugMessage: "model context unavailable for draft.generate",
                recoverAction: "check_model_configuration",
                isRetryable: false
            )
        }

        let fileEvidence = selectedFiles.map { file in
            let blocks = file.parsedBlocks.prefix(6).map { "[\($0.kind.rawValue)] \($0.content)" }.joined(separator: "\n")
            return "file=\(file.name)\n\(blocks)"
        }.joined(separator: "\n\n")

        let searchLines = searchEvidence.map {
            "- \($0.title) | \($0.url) | \($0.snippet)"
        }.joined(separator: "\n")

        let prompt = """
        你要生成 Markdown 文档的结构化 JSON。
        输出必须是一个 JSON object，字段必须完整：
        title, summary[], key_points[], action_items[{owner,deadline,task}], risks[], todo[], references[], source_anchors[{source_type,source_name,location_ref,excerpt}]

        style_profile=\(styleProfile.rawValue)

        输入：
        \(envelopeText)

        文件证据：
        \(fileEvidence.isEmpty ? "(none)" : fileEvidence)

        联网证据：
        \(searchLines.isEmpty ? "(none)" : searchLines)
        """

        let result = try await generationProvider.generateText(
            request: TextGenerationRequest(
                systemPrompt: "你是结构化文档生成器。",
                userPrompt: prompt,
                temperature: 0.1,
                maxOutputTokens: 2200
            ),
            configuration: modelContext.configuration,
            apiKey: modelContext.apiKey
        )

        let candidate = extractJSONCandidate(from: result.outputText)
        guard let data = candidate.data(using: .utf8) else {
            return fallbackDocumentModel(styleProfile: styleProfile, searchEvidence: searchEvidence)
        }

        do {
            let decoded = try JSONDecoder().decode(DecodedDocumentModel.self, from: data)
            return decoded.toRuntimeModel()
        } catch {
            return fallbackDocumentModel(styleProfile: styleProfile, searchEvidence: searchEvidence)
        }
    }

    private func validateAndRepair(
        model: MDDocumentModel,
        searchEvidence: [SearchEvidence],
        selectedText: String?,
        selectedFiles: [SelectedFileInput]
    ) -> MDDocumentModel {
        let title = model.title.trimmedNilIfEmpty ?? "未命名文档"
        let summary = model.summary.isEmpty ? ["已生成文档摘要。"] : model.summary
        let keyPoints = model.keyPoints.isEmpty ? summary : model.keyPoints
        let todo = model.todo.isEmpty ? ["补充细节并复核事实来源"] : model.todo

        let references: [String] = {
            if !model.references.isEmpty {
                return model.references
            }
            return searchEvidence.map { "\($0.title) - \($0.url)" }
        }()

        let rawAnchors: [SourceAnchor] = {
            if !model.sourceAnchors.isEmpty {
                return model.sourceAnchors
            }
            var generated: [SourceAnchor] = []
            if let selectedText = selectedText?.trimmedNilIfEmpty {
                generated.append(SourceAnchor(sourceType: "selected_text", sourceName: "selection", locationRef: "selection:1", excerpt: String(selectedText.prefix(120))))
            }
            for file in selectedFiles.prefix(4) {
                for (index, block) in file.parsedBlocks.prefix(2).enumerated() {
                    generated.append(SourceAnchor(
                        sourceType: "selected_file",
                        sourceName: file.name,
                        locationRef: block.locationRef ?? "\(file.name):\(index + 1)",
                        excerpt: String(block.content.prefix(120))
                    ))
                }
            }
            for evidence in searchEvidence.prefix(4) {
                generated.append(SourceAnchor(
                    sourceType: "web_search",
                    sourceName: evidence.title,
                    locationRef: evidence.url,
                    excerpt: String(evidence.snippet.prefix(120))
                ))
            }
            return generated
        }()
        let anchors = EvidenceResolver().validateAnchors(
            anchors: rawAnchors,
            selectedText: selectedText,
            selectedFiles: selectedFiles,
            searchEvidence: searchEvidence
        )

        return MDDocumentModel(
            title: title,
            summary: summary,
            keyPoints: keyPoints,
            actionItems: model.actionItems,
            risks: model.risks,
            todo: todo,
            references: references,
            sourceAnchors: anchors
        )
    }

    private func renderMarkdown(model: MDDocumentModel, styleProfile: StyleProfile) -> String {
        var lines: [String] = []
        lines.append("# \(model.title)")
        lines.append("")
        lines.append("- style_profile: \(styleProfile.rawValue)")
        lines.append("- generated_at: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        lines.append("## 摘要")
        lines.append("")
        for item in model.summary {
            lines.append("- \(item)")
        }
        lines.append("")

        lines.append("## 关键点")
        lines.append("")
        for item in model.keyPoints {
            lines.append("- \(item)")
        }
        lines.append("")

        lines.append("## 行动项")
        lines.append("")
        if model.actionItems.isEmpty {
            lines.append("- 暂无")
        } else {
            for item in model.actionItems {
                lines.append("- [ ] \(item.task)（负责人：\(item.owner)，截止：\(item.deadline)）")
            }
        }
        lines.append("")

        lines.append("## 风险")
        lines.append("")
        if model.risks.isEmpty {
            lines.append("- 暂无")
        } else {
            for risk in model.risks {
                lines.append("- \(risk)")
            }
        }
        lines.append("")

        lines.append("## 待办")
        lines.append("")
        for item in model.todo {
            lines.append("- [ ] \(item)")
        }
        lines.append("")

        lines.append("## 参考资料")
        lines.append("")
        if model.references.isEmpty {
            lines.append("- 无")
        } else {
            for ref in model.references {
                lines.append("- \(ref)")
            }
        }
        lines.append("")

        lines.append("## Source Anchors")
        lines.append("")
        if model.sourceAnchors.isEmpty {
            lines.append("- 无")
        } else {
            for anchor in model.sourceAnchors {
                lines.append("- [\(anchor.sourceType)] \(anchor.sourceName) | \(anchor.locationRef)")
                lines.append("  - \(anchor.excerpt)")
            }
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private func persist(markdown: String, title: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mdFolder = root.appendingPathComponent("md", isDirectory: true)
        if !fileManager.fileExists(atPath: mdFolder.path) {
            try fileManager.createDirectory(at: mdFolder, withIntermediateDirectories: true)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let slug = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let filename = "\(formatter.string(from: Date()))-\(slug.isEmpty ? "note" : String(slug.prefix(48))).md"
        let fileURL = mdFolder.appendingPathComponent(filename)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func makePayload(
        fileURL: URL,
        markdown: String,
        model: MDDocumentModel,
        stageRecords: [StageRecord],
        searchEvidence: [SearchEvidence],
        command: String?,
        selectedText: String?,
        selectedFiles: [SelectedFileInput]
    ) -> V4ToolValue {
        var sourceNames: [String] = []
        if command?.trimmedNilIfEmpty != nil {
            sourceNames.append("voice")
        }
        if selectedText?.trimmedNilIfEmpty != nil {
            sourceNames.append("selection")
        }
        if !selectedFiles.isEmpty {
            sourceNames.append("files")
        }
        let sources = sourceNames.map(V4ToolValue.string)

        return .object([
            "path": .string(fileURL.path),
            "title": .string(model.title),
            "markdown": .string(markdown),
            "inputSourceBadges": .array(sources),
            "documentModel": encodeToToolValue(model),
            "stageRecords": encodeToToolValue(stageRecords),
            "searchEvidence": encodeToToolValue(searchEvidence),
            "selectedFiles": encodeToToolValue(selectedFiles)
        ])
    }

    private func makeStageRecord(
        name: String,
        startedAt: Date,
        input: String,
        output: String,
        evidence: String
    ) -> StageRecord {
        StageRecord(
            name: name,
            status: "completed",
            durationMS: Int(Date().timeIntervalSince(startedAt) * 1000),
            inputDigest: String(input.prefix(200)),
            outputDigest: String(output.prefix(200)),
            evidence: String(evidence.prefix(400))
        )
    }

    private func semanticModelContext() async throws -> V4PlannerLLM.ModelContext? {
        if let modelContextOverride {
            return modelContextOverride
        }
        guard let modelSlotManager else {
            return nil
        }
        let endpoint = try await modelSlotManager.resolve(.agent)
        guard let baseURL = URL(string: endpoint.baseURLString) else {
            return nil
        }
        let configuration = TextGenerationProviderConfiguration(
            profileID: endpoint.credentialRef?.rawValue ?? endpoint.sourceConfigurationKey,
            providerType: endpoint.providerType,
            providerName: endpoint.providerDisplayName,
            modelName: endpoint.modelName,
            baseURL: baseURL
        )
        let apiKey = try await modelSlotManager.loadAPIKey(for: .agent)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !configuration.providerType.requiresAPIKey || !apiKey.isEmpty else {
            return nil
        }
        return V4PlannerLLM.ModelContext(configuration: configuration, apiKey: apiKey)
    }

    private func extractJSONCandidate(from rawOutput: String) -> String {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```"),
           let start = trimmed.range(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start.lowerBound...end])
        }
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end {
            return String(trimmed[start...end])
        }
        if let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]"), start < end {
            return String(trimmed[start...end])
        }
        return trimmed
    }

    private func fallbackDocumentModel(styleProfile: StyleProfile, searchEvidence: [SearchEvidence]) -> MDDocumentModel {
        let title: String
        switch styleProfile {
        case .meetingNotes:
            title = "会议纪要"
        case .prd:
            title = "PRD 草案"
        case .weeklyReport:
            title = "周报"
        }
        return MDDocumentModel(
            title: title,
            summary: ["已根据输入生成初稿。"],
            keyPoints: ["请补充业务上下文并复核来源。"],
            actionItems: [],
            risks: [],
            todo: ["补充细节", "复核数据"],
            references: searchEvidence.map { "\($0.title) - \($0.url)" },
            sourceAnchors: []
        )
    }

    private func encodeToToolValue<T: Encodable>(_ value: T) -> V4ToolValue {
        guard
            let data = try? JSONEncoder().encode(value),
            let object = try? JSONDecoder().decode(V4ToolValue.self, from: data)
        else {
            return .null
        }
        return object
    }
}

private struct DecodedParsedBlock: Codable {
    let kind: String
    let content: String
    let locationRef: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case content
        case locationRef = "location_ref"
    }
}

private struct DecodedDocumentModel: Codable {
    struct ActionItem: Codable {
        let owner: String
        let deadline: String
        let task: String
    }

    struct SourceAnchor: Codable {
        let sourceType: String
        let sourceName: String
        let locationRef: String
        let excerpt: String

        enum CodingKeys: String, CodingKey {
            case sourceType = "source_type"
            case sourceName = "source_name"
            case locationRef = "location_ref"
            case excerpt
        }
    }

    let title: String
    let summary: [String]
    let keyPoints: [String]
    let actionItems: [ActionItem]
    let risks: [String]
    let todo: [String]
    let references: [String]
    let sourceAnchors: [SourceAnchor]

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case keyPoints = "key_points"
        case actionItems = "action_items"
        case risks
        case todo
        case references
        case sourceAnchors = "source_anchors"
    }

    func toRuntimeModel() -> V4MDPipelineTool.MDDocumentModel {
        V4MDPipelineTool.MDDocumentModel(
            title: title,
            summary: summary,
            keyPoints: keyPoints,
            actionItems: actionItems.map {
                V4MDPipelineTool.ActionItem(owner: $0.owner, deadline: $0.deadline, task: $0.task)
            },
            risks: risks,
            todo: todo,
            references: references,
            sourceAnchors: sourceAnchors.map {
                V4MDPipelineTool.SourceAnchor(
                    sourceType: $0.sourceType,
                    sourceName: $0.sourceName,
                    locationRef: $0.locationRef,
                    excerpt: $0.excerpt
                )
            }
        )
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

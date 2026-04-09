import Foundation

final class V4TextTransformTool: V4Tool, @unchecked Sendable {
    struct ResearchSnippet: Sendable {
        let title: String
        let url: String
        let snippet: String
    }

    typealias ResearchFetcher = @Sendable (_ query: String, _ limit: Int) async -> [ResearchSnippet]

    let spec = V4ToolSpec(
        toolName: "text.transform",
        displayName: "文字处理",
        summary: "按 instruction 处理输入文本，返回文本结果。",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(
            fields: [
                V4ToolInputField(name: "text", kind: .string, summary: "原始文本"),
                V4ToolInputField(name: "instruction", kind: .string, summary: "处理指令")
            ]
        ),
        requiresPermission: true,
        requiredFeature: .textTransform,
        isConcurrencySafe: true,
        mutatesUserData: false,
        supportsStreamingResults: false
    )

    private let modelSlotManager: V4ModelSlotManager?
    private let generationProvider: any TextGenerationProvider
    private let executeHandler: (@Sendable (String, String) async throws -> V4ToolExecutionOutput)?
    private let researchFetcher: ResearchFetcher

    init(
        modelSlotManager: V4ModelSlotManager? = nil,
        generationProvider: any TextGenerationProvider,
        executeHandler: (@Sendable (String, String) async throws -> V4ToolExecutionOutput)? = nil,
        researchFetcher: ResearchFetcher? = nil
    ) {
        self.modelSlotManager = modelSlotManager
        self.generationProvider = generationProvider
        self.executeHandler = executeHandler
        self.researchFetcher = researchFetcher ?? Self.liveResearchFetcher
    }

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        let text = arguments.string(for: "text")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let instruction = arguments.string(for: "instruction")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if text.isEmpty {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`text` 不能为空。",
                messageForDebug: "text empty"
            )
        }
        if instruction.isEmpty {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`instruction` 不能为空。",
                messageForDebug: "instruction empty"
            )
        }
        return nil
    }

    func execute(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let text = arguments.string(for: "text") ?? ""
        let instruction = arguments.string(for: "instruction") ?? ""

        if let executeHandler {
            return try await executeHandler(text, instruction)
        }

        let configuration: TextGenerationProviderConfiguration
        let apiKey: String
        do {
            let endpoint: V4ModelEndpoint
            if let resolved = context.request.modelSlots?.endpoint(for: .text) {
                endpoint = resolved
            } else if let modelSlotManager {
                endpoint = try await modelSlotManager.resolve(.text)
            } else {
                let payload = V4ToolValue.object(
                    [
                        "mode": .string("local_fallback"),
                        "instruction": .string(instruction),
                        "text": .string(text)
                    ]
                )
                return V4ToolExecutionOutput(
                    outputText: text,
                    evidenceSummary: "text.transform fallback=no_provider_store",
                    rawPayload: payload
                )
            }
            configuration = try makeConfiguration(from: endpoint)
            apiKey = if let modelSlotManager {
                try await modelSlotManager.loadAPIKey(for: .text)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } else {
                ""
            }
        } catch let error as V4ModelSlotResolutionError {
            throw V4ToolError(
                code: .modelUnavailable,
                toolID: spec.toolID,
                messageForUser: "文本模型槽位不可用：\(error.message)",
                messageForDebug: "\(error.code.rawValue) source=\(error.sourceConfigurationKey)",
                recoverAction: "check_text_provider",
                isRetryable: false
            )
        } catch {
            throw V4ToolError(
                code: .toolExecutionFailed,
                toolID: spec.toolID,
                messageForUser: "读取文本模型配置失败，请稍后再试。",
                messageForDebug: String(describing: error),
                recoverAction: "check_text_provider",
                isRetryable: false
            )
        }

        guard !configuration.providerType.requiresAPIKey || !apiKey.isEmpty else {
            throw V4ToolError(
                code: .modelUnavailable,
                toolID: spec.toolID,
                messageForUser: "当前没有可用的文本模型 API key，请先在设置里配置。",
                messageForDebug: "rewrite provider api key missing",
                recoverAction: "open_provider_settings",
                isRetryable: false
            )
        }

        let promptStack = context.request.promptStack
        let fallbackSystemPrompt = """
        你是 PulseType 的文字处理工具。
        你只负责根据给定指令处理输入文本。
        只输出最终文本，不要解释，不要复述指令，不要输出思考过程，除非指令明确要求，否则不要添加标题、引号或额外前后缀。
        """
        let systemPrompt = [promptStack?.finalSystemPrompt, promptStack?.finalGuidancePrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let researchSnippets: [ResearchSnippet] = if shouldDoWebResearch(instruction: instruction, text: text) {
            await researchFetcher(instruction, 6)
        } else {
            []
        }
        let userPrompt = if researchSnippets.isEmpty {
            buildUserPrompt(
                instruction: instruction,
                text: text
            )
        } else {
            buildResearchUserPrompt(
                instruction: instruction,
                text: text,
                snippets: researchSnippets
            )
        }

        let generation = try await generationProvider.generateText(
            request: TextGenerationRequest(
                systemPrompt: systemPrompt.isEmpty ? fallbackSystemPrompt : systemPrompt,
                userPrompt: userPrompt,
                temperature: 0.2,
                maxOutputTokens: nil
            ),
            configuration: configuration,
            apiKey: apiKey
        )
        let anchorTokens = requiredAnchorTokens(
            instruction: instruction,
            text: text
        )
        var finalOutput = normalizedOutputText(from: generation.outputText)
        var anchorRepairApplied = false
        if !anchorTokens.isEmpty, !containsAllAnchorTokens(finalOutput, tokens: anchorTokens) {
            let repaired = try await generationProvider.generateText(
                request: TextGenerationRequest(
                    systemPrompt: systemPrompt.isEmpty ? fallbackSystemPrompt : systemPrompt,
                    userPrompt: buildAnchorRepairPrompt(
                        instruction: instruction,
                        draft: finalOutput,
                        requiredTokens: anchorTokens
                    ),
                    temperature: 0.1,
                    maxOutputTokens: nil
                ),
                configuration: configuration,
                apiKey: apiKey
            )
            finalOutput = normalizedOutputText(from: repaired.outputText)
            anchorRepairApplied = true
        }

        let baseEvidence = "text.transform provider=\(generation.providerName) model=\(generation.modelName)"
        let evidence = if researchSnippets.isEmpty {
            baseEvidence
        } else {
            "\(baseEvidence); research_sources=\(researchSnippets.count)"
        }

        var rawFields: [String: V4ToolValue] = [
            "provider": .string(generation.providerName),
            "model": .string(generation.modelName),
            "outputText": .string(finalOutput)
        ]
        if !researchSnippets.isEmpty {
            rawFields["researchQuery"] = .string(instruction)
            rawFields["researchSources"] = .array(
                researchSnippets.map { snippet in
                    .object(
                        [
                            "title": .string(snippet.title),
                            "url": .string(snippet.url),
                            "snippet": .string(snippet.snippet)
                        ]
                    )
                }
            )
        }
        if !anchorTokens.isEmpty {
            rawFields["requiredAnchors"] = .array(anchorTokens.map(V4ToolValue.string))
            rawFields["anchorRepairApplied"] = .boolean(anchorRepairApplied)
        }

        return V4ToolExecutionOutput(
            outputText: finalOutput,
            evidenceSummary: evidence,
            rawPayload: .object(rawFields)
        )
    }

    private func makeConfiguration(from endpoint: V4ModelEndpoint) throws -> TextGenerationProviderConfiguration {
        guard let baseURL = URL(string: endpoint.baseURLString) else {
            throw V4ModelSlotResolutionError(
                slot: endpoint.slot,
                code: .invalidConfiguration,
                message: "接口地址（Base URL）无效。",
                sourceConfigurationKey: endpoint.sourceConfigurationKey,
                providerIdentifier: endpoint.providerIdentifier
            )
        }
        return TextGenerationProviderConfiguration(
            profileID: endpoint.credentialRef?.rawValue ?? endpoint.sourceConfigurationKey,
            providerType: endpoint.providerType,
            providerName: endpoint.providerDisplayName,
            modelName: endpoint.modelName,
            baseURL: baseURL
        )
    }

    private func buildUserPrompt(
        instruction: String,
        text: String
    ) -> String {
        """
        请严格根据下面的指令处理文本，并且只返回处理后的最终文本。

        处理指令：
        \(instruction)

        待处理文本：
        \(text)
        """
    }

    private func buildResearchUserPrompt(
        instruction: String,
        text: String,
        snippets: [ResearchSnippet]
    ) -> String {
        let sourceText = snippets.enumerated().map { index, snippet in
            "\(index + 1). 标题：\(snippet.title)\n链接：\(snippet.url)\n摘要：\(snippet.snippet)"
        }.joined(separator: "\n\n")
        let material = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let textSection = material.isEmpty ? "(无)" : material

        return """
        你要先依据“联网资料”，再完成写作。只输出最终文章正文，不要解释过程。

        严格要求：
        1) 必须优先使用下面资料，不要臆造具体数据。
        2) 时间、年份、地区等关键实体必须与指令一致，不得私自改写。
        3) 如果资料不足，明确写“资料不足以支持某结论”，但仍给出可用的结构化总结。
        4) 输出用中文，段落清晰，可直接写入备忘录。

        用户指令：
        \(instruction)

        当前文本材料：
        \(textSection)

        联网资料：
        \(sourceText)
        """
    }

    private func shouldDoWebResearch(
        instruction: String,
        text: String
    ) -> Bool {
        let normalized = instruction.lowercased()
        let hasResearchIntent = [
            "调研", "研究", "联网", "最新", "搜集", "查资料",
            "经济", "政策", "市场", "行业", "数据", "报告"
        ].contains { normalized.contains($0) }
        if !hasResearchIntent {
            return false
        }
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedText.isEmpty {
            return true
        }
        return cleanedText == instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requiredAnchorTokens(
        instruction: String,
        text: String
    ) -> [String] {
        let scope = [instruction, text].joined(separator: "\n")
        var tokens = Set<String>()

        if let yearRegex = try? NSRegularExpression(pattern: #"(?<!\d)(?:19|20)\d{2}(?!\d)"#) {
            let range = NSRange(scope.startIndex..<scope.endIndex, in: scope)
            for match in yearRegex.matches(in: scope, options: [], range: range) {
                if let tokenRange = Range(match.range, in: scope) {
                    tokens.insert(String(scope[tokenRange]))
                }
            }
        }

        let semanticAnchors = [
            "上半年", "下半年", "第一季度", "第二季度", "第三季度", "第四季度",
            "中国", "中国经济", "GDP", "进出口", "消费", "投资"
        ]
        for token in semanticAnchors where scope.contains(token) {
            tokens.insert(token)
        }

        return tokens.sorted()
    }

    private func containsAllAnchorTokens(_ output: String, tokens: [String]) -> Bool {
        let normalized = output.lowercased()
        for token in tokens {
            if !normalized.contains(token.lowercased()) {
                return false
            }
        }
        return true
    }

    private func buildAnchorRepairPrompt(
        instruction: String,
        draft: String,
        requiredTokens: [String]
    ) -> String {
        let tokenList = requiredTokens.joined(separator: "、")
        return """
        你需要修正下面这份草稿，使其严格满足指令约束。
        只输出修正后的最终正文，不要解释。

        指令：
        \(instruction)

        必须原样保留并包含这些关键锚点：
        \(tokenList)

        待修正草稿：
        \(draft)
        """
    }

    private static func liveResearchFetcher(
        query: String,
        limit: Int
    ) async -> [ResearchSnippet] {
        guard
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "https://duckduckgo.com/html/?q=\(encoded)&kl=cn-zh")
        else {
            return []
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode),
                let html = String(data: data, encoding: .utf8),
                !html.isEmpty
            else {
                return []
            }
            return parseDuckDuckGoHTML(html, limit: limit)
        } catch {
            return []
        }
    }

    private static func parseDuckDuckGoHTML(
        _ html: String,
        limit: Int
    ) -> [ResearchSnippet] {
        let compact = html.replacingOccurrences(of: "\n", with: " ")
        guard
            let blockRegex = try? NSRegularExpression(
                pattern: #"<div class="result__body".*?</div>\s*</div>"#,
                options: [.caseInsensitive]
            ),
            let titleRegex = try? NSRegularExpression(
                pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
                options: [.caseInsensitive]
            ),
            let snippetRegex = try? NSRegularExpression(
                pattern: #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#,
                options: [.caseInsensitive]
            )
        else {
            return []
        }

        let allRange = NSRange(compact.startIndex..<compact.endIndex, in: compact)
        let blocks = blockRegex.matches(in: compact, options: [], range: allRange)
        var snippets = [ResearchSnippet]()

        for block in blocks {
            guard let blockRange = Range(block.range, in: compact) else {
                continue
            }
            let blockText = String(compact[blockRange])
            let blockNSRange = NSRange(blockText.startIndex..<blockText.endIndex, in: blockText)
            guard
                let titleMatch = titleRegex.firstMatch(in: blockText, options: [], range: blockNSRange),
                titleMatch.numberOfRanges >= 3,
                let urlRange = Range(titleMatch.range(at: 1), in: blockText),
                let titleRange = Range(titleMatch.range(at: 2), in: blockText)
            else {
                continue
            }

            let rawURL = String(blockText[urlRange])
            let resolvedURL = decodeDuckDuckGoRedirectURL(rawURL) ?? rawURL
            let title = htmlToPlainText(String(blockText[titleRange]))
            if title.isEmpty || resolvedURL.isEmpty {
                continue
            }

            let snippet: String
            if
                let snippetMatch = snippetRegex.firstMatch(in: blockText, options: [], range: blockNSRange),
                snippetMatch.numberOfRanges >= 2,
                let snippetRange = Range(snippetMatch.range(at: 1), in: blockText)
            {
                snippet = htmlToPlainText(String(blockText[snippetRange]))
            } else {
                snippet = ""
            }

            snippets.append(
                ResearchSnippet(
                    title: title,
                    url: resolvedURL,
                    snippet: snippet
                )
            )
            if snippets.count >= max(1, limit) {
                break
            }
        }

        return snippets
    }

    private static func decodeDuckDuckGoRedirectURL(_ value: String) -> String? {
        guard
            let components = URLComponents(string: value),
            components.path == "/l/",
            let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        else {
            return nil
        }
        return uddg.removingPercentEncoding ?? uddg
    }

    private static func htmlToPlainText(_ value: String) -> String {
        var plain = value
        let replacements = [
            ("<b>", ""),
            ("</b>", ""),
            ("<em>", ""),
            ("</em>", ""),
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">")
        ]
        for (source, target) in replacements {
            plain = plain.replacingOccurrences(of: source, with: target)
        }
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedOutputText(from rawOutput: String) -> String {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return rawOutput
        }

        if trimmed.hasPrefix("```"), let unfenced = unfencedText(from: trimmed) {
            return unfenced
        }

        return trimmed
    }

    private func unfencedText(from value: String) -> String? {
        let lines = value.components(separatedBy: .newlines)
        guard lines.count >= 3 else {
            return nil
        }

        var body = lines
        if body.first?.hasPrefix("```") == true {
            body.removeFirst()
        }
        if body.last?.hasPrefix("```") == true {
            body.removeLast()
        }

        let candidate = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

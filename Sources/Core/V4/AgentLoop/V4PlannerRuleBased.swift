import Foundation

enum V4RulePlannerHeuristics {
    enum ExternalAction: String, CaseIterable {
        case calendar
        case note
        case mail
        case music
        case feishu
    }

    struct Classification {
        let toolName: String
        let title: String
        let externalActions: Set<ExternalAction>
    }

    private static let timeParser = V4TimeParser()

    static func segments(from command: String) -> [String] {
        let patterns = [
            #"(?i)\s*(然后|再|接着|随后|之后|最后)\s*"#,
            #"(?i)\s*[；;]\s*"#
        ]
        var segments = [command]
        for pattern in patterns {
            segments = segments.flatMap { segment in
                segment.components(separatedByRegex: pattern)
            }
        }
        let cleaned = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? [command.trimmingCharacters(in: .whitespacesAndNewlines)] : cleaned
    }

    static func classification(for segment: String) -> Classification {
        let lowered = segment.lowercased()
        var externalActions = Set<ExternalAction>()

        if containsAny(lowered, tokens: ["飞书", "feishu", "lark", "多维表格", "日历", "云文档"]) {
            externalActions.insert(.feishu)
        }
        if containsAny(lowered, tokens: ["邮件", "mail", "email", "草稿", "邮箱", "发邮件", "写邮件"]) {
            externalActions.insert(.mail)
        }
        if containsAny(lowered, tokens: noteIntentTokens) {
            externalActions.insert(.note)
        }
        if containsAny(lowered, tokens: ["日程", "会议", "calendar", "event", "安排", "课程", "上课", "行程"]) {
            externalActions.insert(.calendar)
        }
        if containsAny(lowered, tokens: ["音乐", "歌曲", "播放", "暂停", "继续播放", "下一首", "上一首", "music", "play", "pause", "放首", "来首", "来一首", "播一下", "放一下", "听一下", "听首"]) {
            externalActions.insert(.music)
        }

        if externalActions.contains(.feishu) {
            return Classification(
                toolName: "feishu.cli",
                title: "执行飞书命令",
                externalActions: externalActions
            )
        }
        if externalActions.contains(.mail) {
            return Classification(
                toolName: "apple.mail.compose",
                title: "整理邮件",
                externalActions: externalActions
            )
        }
        if externalActions.contains(.note) {
            let noteTitle: String
            if containsAny(lowered, tokens: ["查找", "查询", "搜索", "find", "search"]) {
                noteTitle = "检索备忘录"
            } else if containsAny(lowered, tokens: ["追加", "补充", "append", "续写", "加到"]) {
                noteTitle = "追加备忘录"
            } else {
                noteTitle = "写入备忘录"
            }
            return Classification(
                toolName: "apple.notes.create",
                title: noteTitle,
                externalActions: externalActions
            )
        }
        if externalActions.contains(.calendar) {
            return Classification(
                toolName: "apple.calendar.create",
                title: "创建日程",
                externalActions: externalActions
            )
        }
        if externalActions.contains(.music) {
            return Classification(
                toolName: "apple.music.control",
                title: "控制音乐",
                externalActions: externalActions
            )
        }
        if looksLikeTimeMachineRemind(segment) {
            return Classification(
                toolName: "time_machine.remind",
                title: "记录并提醒",
                externalActions: []
            )
        }
        if looksLikeTimeMachineCreate(segment) {
            return Classification(
                toolName: "time_machine.create",
                title: "记录到时光机",
                externalActions: []
            )
        }

        return Classification(
            toolName: "text.transform",
            title: "文字处理",
            externalActions: []
        )
    }

    static func looksLikeTimeMachineIntent(_ value: String) -> Bool {
        looksLikeTimeMachineRemind(value) || looksLikeTimeMachineCreate(value)
    }

    static func mixedExternalFailureMessage(for segments: [String]) -> String? {
        let segmentActions = segments.map { classification(for: $0).externalActions }.filter { !$0.isEmpty }
        guard !segmentActions.isEmpty else {
            return nil
        }

        let flattened = Set(segmentActions.flatMap(\.self))
        if flattened.count > 1 {
            return "这条命令同时涉及多个外部动作，请拆开说。"
        }

        if segmentActions.contains(where: { $0.contains(.feishu) && $0.count > 1 }) {
            return "这条命令同时跨了飞书和其他外部动作，请拆开说。"
        }

        return nil
    }

    static func shouldUseTwoStepNoteFlow(command: String) -> Bool {
        let normalized = command.lowercased()
        let hasNotesIntent = containsAny(normalized, tokens: noteIntentTokens)
        let hasTransformIntent = containsAny(normalized, tokens: transformIntentTokens)
        return hasNotesIntent && hasTransformIntent
    }

    static func hasNotesIntent(_ command: String) -> Bool {
        containsAny(command.lowercased(), tokens: noteIntentTokens)
    }

    static func hasTransformIntent(_ command: String) -> Bool {
        containsAny(command.lowercased(), tokens: transformIntentTokens)
    }

    static func hasSelectionDependentTransformIntent(_ command: String) -> Bool {
        containsAny(command.lowercased(), tokens: selectionDependentTransformTokens)
    }

    static func hasNoteFindIntent(_ command: String) -> Bool {
        containsAny(command.lowercased(), tokens: noteFindIntentTokens)
    }

    private static let noteIntentTokens: [String] = [
        "备忘录", "note", "notes",
        "写进备忘录", "写入备忘录", "记到备忘录", "记录到备忘录",
        "写进文档", "写入文档", "记到文档", "记录到文档", "写到文档", "放到文档", "放进文档"
    ]

    private static let transformIntentTokens: [String] = [
        "整理", "润色", "改写", "重写", "优化", "总结", "摘要", "提炼",
        "翻译", "压缩", "扩写", "美化", "改得", "改成", "改为", "重组",
        "调研", "研究", "思考", "分析", "原创", "写一篇", "文章", "草稿",
        "经济", "趋势", "现状", "数据", "报告", "上半年", "下半年", "同比", "环比",
        "gdp", "cpi", "pmi", "进出口"
    ]

    private static let selectionDependentTransformTokens: [String] = [
        "翻译", "润色", "改写", "重写", "总结", "摘要", "提炼", "压缩", "扩写", "美化", "改成", "改为"
    ]

    private static let noteFindIntentTokens: [String] = [
        "查找", "查询", "搜索", "find", "search", "lookup"
    ]

    private static func containsAny(_ value: String, tokens: [String]) -> Bool {
        tokens.contains { value.contains($0) }
    }

    private static func looksLikeTimeMachineRemind(_ value: String) -> Bool {
        let normalized = value.lowercased()
        if containsAny(normalized, tokens: ["提醒我", "提醒一下", "本地提醒", "叫我", "闹钟"]) {
            return true
        }
        return timeParser.looksLikeTimeExpression(normalized)
    }

    private static func looksLikeTimeMachineCreate(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return containsAny(
            normalized,
            tokens: ["记一下", "记一条", "记下来", "记住", "灵感", "想法", "待办", "todo"]
        )
    }
}

struct V4PlannerRuleBased: V4Planner {
    func plan(for request: V4RunRequest) async throws -> V4Plan {
        let trimmedCommand = request.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            return V4Plan(
                steps: [],
                terminalDecision: V4LoopDecision(
                    action: .fail,
                    message: "命令为空，没法继续执行。",
                    failureCode: .invalidRequest
                )
            )
        }

        if let selectionFallback = selectionToNotesFallbackPlan(for: request, trimmedCommand: trimmedCommand) {
            return selectionFallback
        }

        let segments = V4RulePlannerHeuristics.segments(from: trimmedCommand)
        if let message = V4RulePlannerHeuristics.mixedExternalFailureMessage(for: segments) {
            return V4Plan(
                steps: [],
                terminalDecision: V4LoopDecision(
                    action: .fail,
                    message: message,
                    failureCode: .invalidRequest
                )
            )
        }

        if V4RulePlannerHeuristics.shouldUseTwoStepNoteFlow(command: trimmedCommand) {
            let completedCount = request.stepRecords.count
            if completedCount == 0 {
                return V4Plan(
                    steps: [
                        V4StepRecord(
                            traceID: request.traceID,
                            lane: request.lane,
                            goalSummary: request.goalSummary,
                            title: "文字处理",
                            status: .queued,
                            toolName: "text.transform",
                            inputSummary: summarized(trimmedCommand)
                        )
                    ]
                )
            }
            if completedCount == 1 {
                return V4Plan(
                    steps: [
                        V4StepRecord(
                            traceID: request.traceID,
                            lane: request.lane,
                            goalSummary: request.goalSummary,
                            title: "写入备忘录",
                            status: .queued,
                            toolName: "apple.notes.create",
                            inputSummary: summarized(trimmedCommand)
                        )
                    ]
                )
            }
            return V4Plan(
                steps: [],
                terminalDecision: V4LoopDecision(
                    action: .finish,
                    message: "已完成全部规划步骤。"
                )
            )
        }

        let nextIndex = request.stepRecords.count
        guard nextIndex < segments.count else {
            return V4Plan(
                steps: [],
                terminalDecision: V4LoopDecision(
                    action: .finish,
                    message: "已完成全部规划步骤。"
                )
            )
        }

        let nextSegment = segments[nextIndex]
        let classification = V4RulePlannerHeuristics.classification(for: nextSegment)
        let step = V4StepRecord(
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            title: classification.title,
            status: .queued,
            toolName: classification.toolName,
            inputSummary: summarized(nextSegment)
        )
        return V4Plan(steps: [step])
    }

    private func selectionToNotesFallbackPlan(
        for request: V4RunRequest,
        trimmedCommand: String
    ) -> V4Plan? {
        guard request.lane == .selectionRewrite else {
            return nil
        }
        guard request.selectionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        let normalized = trimmedCommand.lowercased()
        guard normalized == "skill" || normalized == "skills" else {
            return nil
        }
        return V4Plan(
            steps: [
                V4StepRecord(
                    traceID: request.traceID,
                    lane: request.lane,
                    goalSummary: request.goalSummary,
                    title: "写入备忘录",
                    status: .queued,
                    toolName: "apple.notes.create",
                    inputSummary: summarized(trimmedCommand)
                )
            ]
        )
    }

    private func summarized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 120 else {
            return trimmed
        }
        return String(trimmed.prefix(117)) + "..."
    }
}

private extension String {
    func components(separatedByRegex pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [self]
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        let matches = expression.matches(in: self, options: [], range: range)
        guard !matches.isEmpty else {
            return [self]
        }

        var components: [String] = []
        var currentLocation = startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: self) else {
                continue
            }
            components.append(String(self[currentLocation..<matchRange.lowerBound]))
            currentLocation = matchRange.upperBound
        }
        components.append(String(self[currentLocation..<endIndex]))
        return components
    }
}

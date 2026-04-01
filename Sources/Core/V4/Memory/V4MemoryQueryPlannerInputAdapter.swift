import Foundation

protocol V4MemoryQueryPlannerInputAdapting {
    func adapt(request: V4RunRequest, historyEntries: [SessionHistoryEntry]) -> V4RunRequest
}

final class V4MemoryQueryPlannerInputAdapter: V4MemoryQueryPlannerInputAdapting {
    private let bridge: V4MemoryBridge
    private let engine: V4MemoryEngine

    init(
        bridge: V4MemoryBridge = V4MemoryBridge(),
        engine: V4MemoryEngine = V4MemoryEngine()
    ) {
        self.bridge = bridge
        self.engine = engine
    }

    func adapt(request: V4RunRequest, historyEntries: [SessionHistoryEntry]) -> V4RunRequest {
        let memoryEntries = bridge.makeEntries(from: historyEntries)
        engine.rebuild(with: memoryEntries)

        let hits = engine.search(
            V4MemoryQuery(
                commandText: request.inputText,
                lane: request.lane,
                bundleID: request.bundleID,
                topK: 5,
                referenceTime: request.requestedAt
            )
        )

        let memoryHints = hits.map { hit in
            V4MemoryHint(
                id: hit.entry.id,
                score: hit.score,
                summary: summarizedHint(for: hit.entry),
                reason: hit.matchedSummary,
                sourceTimestamp: hit.entry.timestamp,
                lane: hit.entry.lane,
                moduleTags: hit.entry.moduleTags
            )
        }
        let relatedRecentRuns = makeRelatedRecentRuns(from: hits)
        let conflictWarnings = makeConflictWarnings(for: request, from: hits)

        var debugTrace = request.memoryDebugTrace
        debugTrace.append("memory.index.entries=\(memoryEntries.count)")
        debugTrace.append("memory.hits.count=\(hits.count)")
        if !memoryHints.isEmpty {
            let topHints = memoryHints.map { "\($0.id):\(String(format: "%.2f", $0.score))" }.joined(separator: ",")
            debugTrace.append("memory.hints=\(topHints)")
        }
        if !conflictWarnings.isEmpty {
            let warnings = conflictWarnings.map(\.message).joined(separator: " | ")
            debugTrace.append("memory.conflicts=\(warnings)")
        }

        return V4RunRequest(
            sessionID: request.sessionID,
            runID: request.runID,
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            inputText: request.inputText,
            appName: request.appName,
            bundleID: request.bundleID,
            selectionText: request.selectionText,
            enabledFeatureIDs: request.enabledFeatureIDs,
            stepRecords: request.stepRecords,
            evidenceSummary: request.evidenceSummary,
            memoryHints: memoryHints,
            relatedRecentRuns: relatedRecentRuns,
            conflictWarnings: conflictWarnings,
            memoryDebugTrace: debugTrace,
            requestedAt: request.requestedAt
        )
    }

    private func summarizedHint(for entry: V4MemoryEntry) -> String {
        let parts = [
            entry.goalSummary,
            entry.instructionText,
            entry.outputText,
            entry.evidenceSummary
        ].filter { !$0.isEmpty }

        let joined = parts.joined(separator: " | ")
        guard joined.count > 160 else {
            return joined
        }
        return String(joined.prefix(157)) + "..."
    }

    private func makeRelatedRecentRuns(from hits: [V4MemoryHit]) -> [V4RelatedRecentRun] {
        let sorted = hits.sorted { lhs, rhs in
            if lhs.entry.timestamp != rhs.entry.timestamp {
                return lhs.entry.timestamp > rhs.entry.timestamp
            }
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.entry.id < rhs.entry.id
        }

        return Array(sorted.prefix(3)).map { hit in
            V4RelatedRecentRun(
                id: hit.entry.id,
                timestamp: hit.entry.timestamp,
                lane: hit.entry.lane,
                appName: hit.entry.appName,
                bundleID: hit.entry.bundleID,
                goalSummary: hit.entry.goalSummary,
                summary: summarizedHint(for: hit.entry),
                score: hit.score,
                reason: hit.matchedSummary
            )
        }
    }

    private func makeConflictWarnings(
        for request: V4RunRequest,
        from hits: [V4MemoryHit]
    ) -> [V4ConflictWarning] {
        let recentHits = hits
            .filter { request.requestedAt.timeIntervalSince($0.entry.timestamp) <= 72 * 3600 }

        return recentHits.compactMap { hit in
            guard let warning = detectConflict(commandText: request.inputText, hit: hit) else {
                return nil
            }
            return V4ConflictWarning(
                id: "\(hit.entry.id)-conflict",
                message: warning.message,
                relatedEntryID: hit.entry.id,
                reason: warning.reason
            )
        }
    }

    private func detectConflict(commandText: String, hit: V4MemoryHit) -> (message: String, reason: String)? {
        let combinedHistory = [
            hit.entry.instructionText,
            hit.entry.goalSummary,
            hit.entry.outputText
        ]
        .joined(separator: "\n")

        for pair in oppositeActions {
            if commandText.contains(pair.current), combinedHistory.contains(pair.previous) {
                return (
                    "最近刚做过相反动作：\(hit.entry.goalSummary)",
                    "当前命令含“\(pair.current)”，历史里命中过“\(pair.previous)”"
                )
            }
            if commandText.contains(pair.previous), combinedHistory.contains(pair.current) {
                return (
                    "最近刚做过相反动作：\(hit.entry.goalSummary)",
                    "当前命令含“\(pair.previous)”，历史里命中过“\(pair.current)”"
                )
            }
        }

        return nil
    }

    private let oppositeActions: [(current: String, previous: String)] = [
        ("关闭", "打开"),
        ("禁用", "启用"),
        ("停止", "开始"),
        ("暂停", "播放"),
        ("删除", "添加"),
        ("撤销", "发送")
    ]
}

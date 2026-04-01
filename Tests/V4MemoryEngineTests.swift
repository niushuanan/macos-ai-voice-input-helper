import XCTest
@testable import PulseType

final class V4MemoryEngineTests: XCTestCase {
    func testIndexBuildFromHistoryEntries() {
        let bridge = V4MemoryBridge()
        let historyEntries = [
            makeHistoryEntry(
                timestamp: Date(timeIntervalSince1970: 1_710_000_000),
                mode: .selectionRewrite,
                appName: "备忘录",
                bundleID: "com.apple.Notes",
                inputText: "把这段话整理好",
                outputText: "已写入备忘录",
                instructionText: "写进备忘录",
                goalSummary: "把会议纪要写进备忘录",
                stepSummaries: ["text.transform:整理纪要", "apple.notes.create:已写入备忘录"],
                evidenceSummary: "apple.notes.create note_id=123",
                appliedSkills: [.spokenFilter]
            ),
            makeHistoryEntry(
                timestamp: Date(timeIntervalSince1970: 1_710_000_100),
                mode: .brainstorm,
                appName: "飞书",
                bundleID: "com.lark.app",
                inputText: "讨论一下发布计划",
                outputText: "发布计划摘要",
                goalSummary: nil,
                stepSummaries: nil,
                evidenceSummary: nil
            )
        ]

        let entries = bridge.makeEntries(from: historyEntries)
        let engine = V4MemoryEngine(entries: entries)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].lane, .selectionRewrite)
        XCTAssertEqual(entries[0].goalSummary, "把会议纪要写进备忘录")
        XCTAssertEqual(entries[0].stepSummaries.count, 2)
        XCTAssertEqual(entries[0].evidenceSummary, "apple.notes.create note_id=123")
        XCTAssertEqual(entries[0].appliedSkills, ["spokenFilter"])
        XCTAssertTrue(entries[0].moduleTags.contains("magician"))
        XCTAssertNotNil(engine.index.postings["备忘录"])
    }

    func testKeywordSearchReturnsTopK() {
        let baseDate = Date(timeIntervalSince1970: 1_710_000_000)
        let entries = (0..<6).map { offset in
            V4MemoryEntry(
                id: "entry-\(offset)",
                timestamp: baseDate.addingTimeInterval(Double(offset) * 60),
                lane: .selectionRewrite,
                appName: "备忘录",
                bundleID: "com.apple.Notes",
                moduleTags: ["magician"],
                inputText: "会议纪要 \(offset)",
                outputText: "备忘录内容 \(offset)",
                instructionText: "写进备忘录",
                goalSummary: "把会议纪要写进备忘录",
                stepSummaries: ["text.transform"],
                evidenceSummary: "备忘录已保存",
                appliedSkills: [],
                source: "history",
                traceID: nil,
                sessionID: nil
            )
        }
        let engine = V4MemoryEngine(entries: entries)

        let hits = engine.search(
            V4MemoryQuery(
                commandText: "把会议纪要写进备忘录",
                lane: .selectionRewrite,
                bundleID: "com.apple.Notes",
                topK: 5,
                referenceTime: baseDate.addingTimeInterval(600)
            )
        )

        XCTAssertEqual(hits.count, 5)
        XCTAssertTrue(hits.allSatisfy { !$0.reasons.isEmpty })
        XCTAssertGreaterThanOrEqual(hits[0].score, hits[1].score)
    }

    func testLaneMatchBoostsScore() {
        let baseDate = Date(timeIntervalSince1970: 1_710_000_000)
        let engine = V4MemoryEngine(
            entries: [
                makeMemoryEntry(
                    id: "selection",
                    timestamp: baseDate,
                    lane: .selectionRewrite,
                    bundleID: "com.apple.Notes"
                ),
                makeMemoryEntry(
                    id: "dictation",
                    timestamp: baseDate,
                    lane: .directDictation,
                    bundleID: "com.apple.Notes"
                )
            ]
        )

        let hits = engine.search(
            V4MemoryQuery(
                commandText: "写进备忘录",
                lane: .selectionRewrite,
                bundleID: "com.apple.Notes",
                referenceTime: baseDate
            )
        )

        XCTAssertEqual(hits.first?.entry.id, "selection")
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
    }

    func testRecencyDecayAffectsRanking() {
        let referenceTime = Date(timeIntervalSince1970: 1_710_100_000)
        let engine = V4MemoryEngine(
            entries: [
                makeMemoryEntry(
                    id: "older",
                    timestamp: referenceTime.addingTimeInterval(-20 * 24 * 3600),
                    lane: .selectionRewrite,
                    bundleID: "com.apple.Notes"
                ),
                makeMemoryEntry(
                    id: "recent",
                    timestamp: referenceTime.addingTimeInterval(-2 * 3600),
                    lane: .selectionRewrite,
                    bundleID: "com.apple.Notes"
                )
            ]
        )

        let hits = engine.search(
            V4MemoryQuery(
                commandText: "写进备忘录",
                lane: .selectionRewrite,
                bundleID: "com.apple.Notes",
                referenceTime: referenceTime
            )
        )

        XCTAssertEqual(hits.first?.entry.id, "recent")
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
    }

    func testStableSortForEqualScore() {
        let timestamp = Date(timeIntervalSince1970: 1_710_000_000)
        let engine = V4MemoryEngine(
            entries: [
                makeMemoryEntry(
                    id: "first",
                    timestamp: timestamp,
                    lane: .directDictation,
                    bundleID: "com.apple.TextEdit"
                ),
                makeMemoryEntry(
                    id: "second",
                    timestamp: timestamp,
                    lane: .directDictation,
                    bundleID: "com.apple.TextEdit"
                )
            ]
        )

        let hits = engine.search(
            V4MemoryQuery(
                commandText: "写进备忘录",
                lane: .selectionRewrite,
                bundleID: "com.apple.Notes",
                referenceTime: timestamp
            )
        )

        XCTAssertEqual(hits.map(\.entry.id), ["first", "second"])
    }

    func testPlannerInputAdapterIncludesMemoryHints() {
        let adapter = V4MemoryQueryPlannerInputAdapter()
        let now = Date(timeIntervalSince1970: 1_710_200_000)
        let historyEntries = [
            makeHistoryEntry(
                timestamp: now.addingTimeInterval(-3600),
                mode: .selectionRewrite,
                appName: "音乐",
                bundleID: "com.apple.Music",
                inputText: "播放音乐",
                outputText: "已开始播放",
                instructionText: "打开音乐",
                goalSummary: "打开音乐继续播放",
                stepSummaries: ["apple.music.control:已开始播放"],
                evidenceSummary: "apple.music.control action=play"
            )
        ]
        let request = V4RunRequest(
            traceID: V4TraceID(rawValue: "trace-memory"),
            lane: .selectionRewrite,
            goalSummary: "关闭音乐",
            inputText: "关闭音乐",
            appName: "音乐",
            bundleID: "com.apple.Music",
            selectionText: nil,
            requestedAt: now
        )

        let adapted = adapter.adapt(request: request, historyEntries: historyEntries)

        XCTAssertFalse(adapted.memoryHints.isEmpty)
        XCTAssertFalse(adapted.relatedRecentRuns.isEmpty)
        XCTAssertFalse(adapted.conflictWarnings.isEmpty)
        XCTAssertTrue(adapted.memoryDebugTrace.contains { $0.contains("memory.hits.count=") })
    }

    private func makeHistoryEntry(
        timestamp: Date,
        mode: SessionHistoryMode,
        appName: String,
        bundleID: String,
        inputText: String,
        outputText: String?,
        instructionText: String? = nil,
        goalSummary: String?,
        stepSummaries: [String]?,
        evidenceSummary: String?,
        appliedSkills: [SkillRuleID] = []
    ) -> SessionHistoryEntry {
        SessionHistoryEntry(
            timestamp: timestamp,
            mode: mode,
            appName: appName,
            bundleID: bundleID,
            inputText: inputText,
            outputText: outputText,
            brainstormDialogueText: mode == .brainstorm ? inputText : nil,
            instructionText: instructionText,
            magicianGoalSummary: goalSummary,
            magicianStepSummaries: stepSummaries,
            magicianEvidenceSummary: evidenceSummary,
            status: .success,
            appliedSkills: appliedSkills
        )
    }

    private func makeMemoryEntry(
        id: String,
        timestamp: Date,
        lane: V4Lane,
        bundleID: String
    ) -> V4MemoryEntry {
        V4MemoryEntry(
            id: id,
            timestamp: timestamp,
            lane: lane,
            appName: "测试应用",
            bundleID: bundleID,
            moduleTags: ["magician"],
            inputText: "把纪要整理一下",
            outputText: "已写入备忘录",
            instructionText: "写进备忘录",
            goalSummary: "把会议纪要写进备忘录",
            stepSummaries: ["text.transform:整理", "apple.notes.create:保存"],
            evidenceSummary: "apple.notes.create note_id=1",
            appliedSkills: [],
            source: "history",
            traceID: nil,
            sessionID: nil
        )
    }
}

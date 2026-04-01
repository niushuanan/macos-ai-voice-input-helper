import Foundation

private struct V4MemoryScoreParts {
    var keywordScore: Double = 0
    var fieldScore: Double = 0
    var matchedTokens = Set<String>()
    var fieldTotals: [V4MemorySearchField: Double] = [:]
}

final class V4MemoryEngine {
    private(set) var index: V4MemoryIndex

    init(entries: [V4MemoryEntry] = []) {
        self.index = V4MemoryIndex(entries: entries)
    }

    func rebuild(with entries: [V4MemoryEntry]) {
        index = V4MemoryIndex(entries: entries)
    }

    func search(_ query: V4MemoryQuery) -> [V4MemoryHit] {
        let queryTokens = Array(Set(V4MemoryIndex.tokenize(query.commandText)))
        guard !queryTokens.isEmpty else {
            return []
        }

        var scoresByEntry: [Int: V4MemoryScoreParts] = [:]
        for token in queryTokens {
            guard let postings = index.postings[token] else {
                continue
            }
            for posting in postings {
                var current = scoresByEntry[posting.entryIndex, default: V4MemoryScoreParts()]
                current.keywordScore += 1 + (Double(posting.occurrenceCount - 1) * 0.25)
                current.fieldScore += fieldWeight(for: posting.field) * Double(posting.occurrenceCount)
                current.matchedTokens.insert(token)
                current.fieldTotals[posting.field, default: 0] += fieldWeight(for: posting.field) * Double(posting.occurrenceCount)
                scoresByEntry[posting.entryIndex] = current
            }
        }

        let sortedHits = scoresByEntry.compactMap { entryIndex, scoreParts -> (V4MemoryHit, Int)? in
            let indexedEntry = index.entries[entryIndex]
            guard query.timeWindow?.contains(indexedEntry.entry.timestamp) ?? true else {
                return nil
            }

            let laneBonus = indexedEntry.entry.lane == query.lane ? 3.0 : 0
            let appBonus = matches(bundleID: indexedEntry.entry.bundleID, queryBundleID: query.bundleID) ? 2.0 : 0
            let recencyFactor = timeDecayFactor(
                timestamp: indexedEntry.entry.timestamp,
                referenceTime: query.referenceTime
            )
            let finalScore = (scoreParts.keywordScore + scoreParts.fieldScore + laneBonus + appBonus) * recencyFactor

            let hit = V4MemoryHit(
                entry: indexedEntry.entry,
                score: finalScore,
                reasons: reasons(
                    scoreParts: scoreParts,
                    laneBonus: laneBonus,
                    appBonus: appBonus,
                    recencyFactor: recencyFactor
                )
            )
            return (hit, indexedEntry.orderIndex)
        }
        .sorted { lhs, rhs in
            if lhs.0.score != rhs.0.score {
                return lhs.0.score > rhs.0.score
            }
            return lhs.1 < rhs.1
        }

        return Array(sortedHits.prefix(query.topK).map(\.0))
    }

    private func fieldWeight(for field: V4MemorySearchField) -> Double {
        switch field {
        case .instruction:
            return 6
        case .goal:
            return 5
        case .output:
            return 4
        case .input:
            return 3
        case .steps:
            return 2.5
        case .evidence:
            return 2
        case .tags:
            return 2.5
        }
    }

    private func matches(bundleID: String?, queryBundleID: String?) -> Bool {
        guard
            let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
            let queryBundleID = queryBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleID.isEmpty,
            !queryBundleID.isEmpty
        else {
            return false
        }
        return bundleID == queryBundleID
    }

    private func timeDecayFactor(timestamp: Date, referenceTime: Date) -> Double {
        let ageHours = max(0, referenceTime.timeIntervalSince(timestamp) / 3600)
        return 0.35 + (0.65 * exp(-(ageHours / 168)))
    }

    private func reasons(
        scoreParts: V4MemoryScoreParts,
        laneBonus: Double,
        appBonus: Double,
        recencyFactor: Double
    ) -> [String] {
        var result: [String] = []

        if !scoreParts.matchedTokens.isEmpty {
            let tokens = scoreParts.matchedTokens.sorted().joined(separator: "、")
            result.append("关键词命中：\(tokens)")
        }

        if !scoreParts.fieldTotals.isEmpty {
            let fields = scoreParts.fieldTotals
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value {
                        return lhs.value > rhs.value
                    }
                    return lhs.key.rawValue < rhs.key.rawValue
                }
                .map { "\($0.key.rawValue)(\(String(format: "%.1f", $0.value)))" }
                .joined(separator: "、")
            result.append("字段权重：\(fields)")
        }

        if laneBonus > 0 {
            result.append("lane 匹配 +\(Int(laneBonus))")
        }

        if appBonus > 0 {
            result.append("app 匹配 +\(Int(appBonus))")
        }

        result.append("时间衰减：\(String(format: "%.3f", recencyFactor))")
        return result
    }
}

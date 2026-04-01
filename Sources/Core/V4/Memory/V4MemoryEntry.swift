import Foundation

struct V4MemoryEntry: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let timestamp: Date
    let lane: V4Lane
    let appName: String?
    let bundleID: String?
    let moduleTags: [String]
    let inputText: String
    let outputText: String
    let instructionText: String
    let goalSummary: String
    let stepSummaries: [String]
    let evidenceSummary: String
    let appliedSkills: [String]
    let source: String
    let traceID: String?
    let sessionID: String?
}

struct V4MemoryTimeWindow: Codable, Equatable, Sendable {
    let start: Date?
    let end: Date?

    func contains(_ date: Date) -> Bool {
        if let start, date < start {
            return false
        }
        if let end, date > end {
            return false
        }
        return true
    }
}

struct V4MemoryQuery: Codable, Equatable, Sendable {
    let commandText: String
    let lane: V4Lane
    let bundleID: String?
    let timeWindow: V4MemoryTimeWindow?
    let topK: Int
    let referenceTime: Date

    init(
        commandText: String,
        lane: V4Lane,
        bundleID: String? = nil,
        timeWindow: V4MemoryTimeWindow? = nil,
        topK: Int = 5,
        referenceTime: Date = Date()
    ) {
        self.commandText = commandText
        self.lane = lane
        self.bundleID = bundleID
        self.timeWindow = timeWindow
        self.topK = max(1, topK)
        self.referenceTime = referenceTime
    }
}

struct V4MemoryHit: Codable, Equatable, Sendable {
    let entry: V4MemoryEntry
    let score: Double
    let reasons: [String]

    var matchedSummary: String {
        reasons.joined(separator: "；")
    }
}

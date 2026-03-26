import Foundation

enum SessionHistoryMode: String, Codable, Equatable {
    case dictation
    case selectionRewrite
    case brainstorm
}

enum SessionHistoryStatus: String, Codable, Equatable {
    case success
    case failed
    case cancelled
}

enum LocalHistoryFilter: String, CaseIterable, Identifiable {
    case all
    case dictation
    case selectionRewrite
    case brainstorm
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .dictation:
            return "普通听写"
        case .selectionRewrite:
            return "魔法师"
        case .brainstorm:
            return "头脑风暴（Beta）"
        case .failed:
            return "失败"
        }
    }
}

struct SessionHistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let mode: SessionHistoryMode
    let appName: String
    let bundleID: String
    let inputText: String
    let outputText: String?
    let brainstormDialogueText: String?
    let instructionText: String?
    let transcriptionProvider: String?
    let transcriptionModel: String?
    let rewriteProvider: String?
    let rewriteModel: String?
    let outputPath: TextOutputPath?
    let status: SessionHistoryStatus
    let errorMessage: String?
    let audioDurationSeconds: Double?
    let appliedSkills: [SkillRuleID]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        mode: SessionHistoryMode,
        appName: String,
        bundleID: String,
        inputText: String,
        outputText: String?,
        brainstormDialogueText: String? = nil,
        instructionText: String? = nil,
        transcriptionProvider: String? = nil,
        transcriptionModel: String? = nil,
        rewriteProvider: String? = nil,
        rewriteModel: String? = nil,
        outputPath: TextOutputPath? = nil,
        status: SessionHistoryStatus,
        errorMessage: String? = nil,
        audioDurationSeconds: Double? = nil,
        appliedSkills: [SkillRuleID] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.mode = mode
        self.appName = appName
        self.bundleID = bundleID
        self.inputText = inputText
        self.outputText = outputText
        self.brainstormDialogueText = brainstormDialogueText
        self.instructionText = instructionText
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionModel = transcriptionModel
        self.rewriteProvider = rewriteProvider
        self.rewriteModel = rewriteModel
        self.outputPath = outputPath
        self.status = status
        self.errorMessage = errorMessage
        self.audioDurationSeconds = audioDurationSeconds
        self.appliedSkills = appliedSkills
    }

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case mode
        case appName
        case bundleID
        case inputText
        case outputText
        case brainstormDialogueText
        case instructionText
        case transcriptionProvider
        case transcriptionModel
        case rewriteProvider
        case rewriteModel
        case outputPath
        case status
        case errorMessage
        case audioDurationSeconds
        case appliedSkills
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        mode = try container.decode(SessionHistoryMode.self, forKey: .mode)
        appName = try container.decode(String.self, forKey: .appName)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        inputText = try container.decode(String.self, forKey: .inputText)
        outputText = try container.decodeIfPresent(String.self, forKey: .outputText)
        brainstormDialogueText = try container.decodeIfPresent(String.self, forKey: .brainstormDialogueText)
        instructionText = try container.decodeIfPresent(String.self, forKey: .instructionText)
        transcriptionProvider = try container.decodeIfPresent(String.self, forKey: .transcriptionProvider)
        transcriptionModel = try container.decodeIfPresent(String.self, forKey: .transcriptionModel)
        rewriteProvider = try container.decodeIfPresent(String.self, forKey: .rewriteProvider)
        rewriteModel = try container.decodeIfPresent(String.self, forKey: .rewriteModel)
        outputPath = try container.decodeIfPresent(TextOutputPath.self, forKey: .outputPath)
        status = try container.decode(SessionHistoryStatus.self, forKey: .status)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        audioDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .audioDurationSeconds)
        appliedSkills = try container.decodeIfPresent([SkillRuleID].self, forKey: .appliedSkills) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(mode, forKey: .mode)
        try container.encode(appName, forKey: .appName)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(inputText, forKey: .inputText)
        try container.encodeIfPresent(outputText, forKey: .outputText)
        try container.encodeIfPresent(brainstormDialogueText, forKey: .brainstormDialogueText)
        try container.encodeIfPresent(instructionText, forKey: .instructionText)
        try container.encodeIfPresent(transcriptionProvider, forKey: .transcriptionProvider)
        try container.encodeIfPresent(transcriptionModel, forKey: .transcriptionModel)
        try container.encodeIfPresent(rewriteProvider, forKey: .rewriteProvider)
        try container.encodeIfPresent(rewriteModel, forKey: .rewriteModel)
        try container.encodeIfPresent(outputPath, forKey: .outputPath)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(audioDurationSeconds, forKey: .audioDurationSeconds)
        try container.encode(appliedSkills, forKey: .appliedSkills)
    }
}

struct HistoryStatisticsSnapshot: Equatable {
    let totalDurationSeconds: Double
    let totalCharacters: Int
    let charactersPerMinute: Double

    static let zero = HistoryStatisticsSnapshot(
        totalDurationSeconds: 0,
        totalCharacters: 0,
        charactersPerMinute: 0
    )
}

struct HistoryLifetimeSnapshot: Codable, Equatable {
    let totalDialogueDurationSeconds: Double
    let totalInputCharacters: Int
    let averageCharactersPerMinute: Double
    let savedTypingSeconds: Double
    let speedSampleCount: Int

    init(
        totalDialogueDurationSeconds: Double,
        totalInputCharacters: Int,
        averageCharactersPerMinute: Double,
        savedTypingSeconds: Double,
        speedSampleCount: Int = 0
    ) {
        self.totalDialogueDurationSeconds = totalDialogueDurationSeconds
        self.totalInputCharacters = totalInputCharacters
        self.averageCharactersPerMinute = averageCharactersPerMinute
        self.savedTypingSeconds = savedTypingSeconds
        self.speedSampleCount = speedSampleCount
    }

    enum CodingKeys: String, CodingKey {
        case totalDialogueDurationSeconds
        case totalInputCharacters
        case averageCharactersPerMinute
        case savedTypingSeconds
        case speedSampleCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalDialogueDurationSeconds = try container.decode(Double.self, forKey: .totalDialogueDurationSeconds)
        totalInputCharacters = try container.decode(Int.self, forKey: .totalInputCharacters)
        averageCharactersPerMinute = try container.decode(Double.self, forKey: .averageCharactersPerMinute)
        savedTypingSeconds = try container.decode(Double.self, forKey: .savedTypingSeconds)
        speedSampleCount = try container.decodeIfPresent(Int.self, forKey: .speedSampleCount) ?? 0
    }

    static let zero = HistoryLifetimeSnapshot(
        totalDialogueDurationSeconds: 0,
        totalInputCharacters: 0,
        averageCharactersPerMinute: 0,
        savedTypingSeconds: 0,
        speedSampleCount: 0
    )
}

@MainActor
final class LocalHistoryStore: ObservableObject {
    @Published private(set) var entries: [SessionHistoryEntry] = []
    @Published private(set) var lifetimeSnapshot: HistoryLifetimeSnapshot = .zero

    private let entriesFileURL: URL
    private let lifetimeFileURL: URL
    private let fileManager: FileManager
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder
    private let maxEntries: Int
    private let typingBaselineCPM: Double

    init(
        historyDirectory: URL,
        fileManager: FileManager = .default,
        maxEntries: Int = 3000,
        typingBaselineCPM: Double = 60
    ) {
        self.fileManager = fileManager
        self.entriesFileURL = historyDirectory.appendingPathComponent("session-history-v1.json", isDirectory: false)
        self.lifetimeFileURL = historyDirectory.appendingPathComponent("lifetime-stats-v1.json", isDirectory: false)
        self.maxEntries = maxEntries
        self.typingBaselineCPM = typingBaselineCPM
        self.jsonDecoder = JSONDecoder()
        self.jsonDecoder.dateDecodingStrategy = .iso8601
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.dateEncodingStrategy = .iso8601
        self.jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        loadEntries()
        loadLifetimeSnapshot()
    }

    func append(_ entry: SessionHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }

        if let contribution = lifetimeContribution(for: entry) {
            let nextDuration = lifetimeSnapshot.totalDialogueDurationSeconds + contribution.sampledDurationSeconds
            let nextCharacters = lifetimeSnapshot.totalInputCharacters + contribution.totalCharacters
            let nextSampleCharacters = sampledCharacters(from: lifetimeSnapshot) + Double(contribution.sampledCharacters)
            let nextSpeedSampleCount = lifetimeSnapshot.speedSampleCount + contribution.speedSampleCount
            lifetimeSnapshot = makeLifetimeSnapshot(
                totalDurationSeconds: nextDuration,
                totalCharacters: nextCharacters,
                sampledCharacters: nextSampleCharacters,
                speedSampleCount: nextSpeedSampleCount
            )
            persistLifetimeSnapshot()
        }

        persistEntries()
    }

    func delete(entryID: UUID) {
        entries.removeAll { $0.id == entryID }
        persistEntries()
    }

    func clearAll() {
        entries = []
        if fileManager.fileExists(atPath: entriesFileURL.path) {
            try? fileManager.removeItem(at: entriesFileURL)
        }
    }

    func lifetimeStatistics() -> HistoryLifetimeSnapshot {
        lifetimeSnapshot
    }

    func entries(matching filter: LocalHistoryFilter) -> [SessionHistoryEntry] {
        switch filter {
        case .all:
            return entries
        case .dictation:
            return entries.filter { $0.mode == .dictation }
        case .selectionRewrite:
            return entries.filter { $0.mode == .selectionRewrite }
        case .brainstorm:
            return entries.filter { $0.mode == .brainstorm }
        case .failed:
            return entries.filter { $0.status == .failed }
        }
    }

    func todayStatistics(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HistoryStatisticsSnapshot {
        let todayEntries = entries.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
        guard !todayEntries.isEmpty else {
            return .zero
        }

        var totalDuration: Double = 0
        var totalCharacters: Int = 0

        for entry in todayEntries {
            let text = (entry.outputText ?? entry.inputText).trimmingCharacters(in: .whitespacesAndNewlines)
            let charCount = text.count
            totalCharacters += charCount

            let rawDuration = max(0, entry.audioDurationSeconds ?? 0)
            if rawDuration > 0 {
                totalDuration += rawDuration
            } else if charCount > 0 {
                // Keep metrics readable even for old history rows without duration.
                let estimatedDuration = max(1.2, Double(charCount) / 4.0)
                totalDuration += estimatedDuration
            }
        }

        let charactersPerMinute: Double
        if totalDuration > 0 {
            charactersPerMinute = (Double(totalCharacters) / totalDuration) * 60
        } else {
            charactersPerMinute = 0
        }

        return HistoryStatisticsSnapshot(
            totalDurationSeconds: totalDuration,
            totalCharacters: totalCharacters,
            charactersPerMinute: charactersPerMinute
        )
    }

    private func loadEntries() {
        guard fileManager.fileExists(atPath: entriesFileURL.path) else {
            entries = []
            return
        }

        guard
            let data = try? Data(contentsOf: entriesFileURL),
            let loaded = try? jsonDecoder.decode([SessionHistoryEntry].self, from: data)
        else {
            entries = []
            return
        }

        entries = loaded.sorted(by: { $0.timestamp > $1.timestamp })
    }

    private func persistEntries() {
        guard let data = try? jsonEncoder.encode(entries) else {
            return
        }
        try? data.write(to: entriesFileURL, options: .atomic)
    }

    private func loadLifetimeSnapshot() {
        guard fileManager.fileExists(atPath: lifetimeFileURL.path) else {
            lifetimeSnapshot = recalculateLifetimeSnapshotFromEntries()
            persistLifetimeSnapshot()
            return
        }

        guard
            let data = try? Data(contentsOf: lifetimeFileURL),
            let decoded = try? jsonDecoder.decode(HistoryLifetimeSnapshot.self, from: data)
        else {
            lifetimeSnapshot = recalculateLifetimeSnapshotFromEntries()
            persistLifetimeSnapshot()
            return
        }

        // 旧快照没有 speedSampleCount，统一改用真实时长口径重算。
        if !containsSpeedSampleCountKey(in: data) {
            lifetimeSnapshot = recalculateLifetimeSnapshotFromEntries()
            persistLifetimeSnapshot()
            return
        }

        let sanitized = makeLifetimeSnapshot(
            totalDurationSeconds: decoded.totalDialogueDurationSeconds,
            totalCharacters: decoded.totalInputCharacters,
            sampledCharacters: sampledCharacters(from: decoded),
            speedSampleCount: decoded.speedSampleCount
        )
        lifetimeSnapshot = sanitized
        if sanitized != decoded {
            persistLifetimeSnapshot()
        }
    }

    private func persistLifetimeSnapshot() {
        guard let data = try? jsonEncoder.encode(lifetimeSnapshot) else {
            return
        }
        try? data.write(to: lifetimeFileURL, options: .atomic)
    }

    private func recalculateLifetimeSnapshotFromEntries() -> HistoryLifetimeSnapshot {
        var totalDuration: Double = 0
        var totalCharacters: Int = 0
        var sampledCharacters: Int = 0
        var speedSampleCount: Int = 0

        for entry in entries {
            guard let contribution = lifetimeContribution(for: entry) else {
                continue
            }
            totalDuration += contribution.sampledDurationSeconds
            totalCharacters += contribution.totalCharacters
            sampledCharacters += contribution.sampledCharacters
            speedSampleCount += contribution.speedSampleCount
        }

        return makeLifetimeSnapshot(
            totalDurationSeconds: totalDuration,
            totalCharacters: totalCharacters,
            sampledCharacters: Double(sampledCharacters),
            speedSampleCount: speedSampleCount
        )
    }

    private func lifetimeContribution(
        for entry: SessionHistoryEntry
    ) -> (
        sampledDurationSeconds: Double,
        totalCharacters: Int,
        sampledCharacters: Int,
        speedSampleCount: Int
    )? {
        guard
            entry.mode == .dictation,
            entry.status == .success
        else {
            return nil
        }

        let text = (entry.outputText ?? entry.inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        let charCount = text.count
        guard charCount > 0 else {
            return nil
        }

        let rawDuration = max(0, entry.audioDurationSeconds ?? 0)
        let speedSampleCount = rawDuration > 0 ? 1 : 0
        let sampledCharacters = rawDuration > 0 ? charCount : 0

        return (
            sampledDurationSeconds: rawDuration,
            totalCharacters: charCount,
            sampledCharacters: sampledCharacters,
            speedSampleCount: speedSampleCount
        )
    }

    private func makeLifetimeSnapshot(
        totalDurationSeconds: Double,
        totalCharacters: Int,
        sampledCharacters: Double,
        speedSampleCount: Int
    ) -> HistoryLifetimeSnapshot {
        let safeDuration = max(0, totalDurationSeconds)
        let safeCharacters = max(0, totalCharacters)
        let safeSampledCharacters = max(0, sampledCharacters)
        let safeSpeedSampleCount = max(0, speedSampleCount)

        let averageCharactersPerMinute: Double
        if safeDuration > 0, safeSpeedSampleCount > 0 {
            averageCharactersPerMinute = (safeSampledCharacters / safeDuration) * 60
        } else {
            averageCharactersPerMinute = 0
        }

        let typingSeconds = (safeSampledCharacters / max(1, typingBaselineCPM)) * 60
        let savedTypingSeconds = max(typingSeconds - safeDuration, 0)

        return HistoryLifetimeSnapshot(
            totalDialogueDurationSeconds: safeDuration,
            totalInputCharacters: safeCharacters,
            averageCharactersPerMinute: averageCharactersPerMinute,
            savedTypingSeconds: savedTypingSeconds,
            speedSampleCount: safeSpeedSampleCount
        )
    }

    private func sampledCharacters(from snapshot: HistoryLifetimeSnapshot) -> Double {
        guard snapshot.totalDialogueDurationSeconds > 0 else {
            return 0
        }
        return max(
            0,
            snapshot.averageCharactersPerMinute
                * snapshot.totalDialogueDurationSeconds
                / 60
        )
    }

    private func containsSpeedSampleCountKey(in data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return false
        }
        return dictionary["speedSampleCount"] != nil
    }
}

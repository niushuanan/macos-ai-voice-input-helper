import Foundation

enum SessionHistoryMode: String, Codable, Equatable {
    case dictation
    case selectionRewrite
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
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .dictation:
            return "普通听写"
        case .selectionRewrite:
            return "选区改写"
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
    let instructionText: String?
    let transcriptionProvider: String?
    let transcriptionModel: String?
    let rewriteProvider: String?
    let rewriteModel: String?
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
        instructionText: String? = nil,
        transcriptionProvider: String? = nil,
        transcriptionModel: String? = nil,
        rewriteProvider: String? = nil,
        rewriteModel: String? = nil,
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
        self.instructionText = instructionText
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionModel = transcriptionModel
        self.rewriteProvider = rewriteProvider
        self.rewriteModel = rewriteModel
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
        case instructionText
        case transcriptionProvider
        case transcriptionModel
        case rewriteProvider
        case rewriteModel
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
        instructionText = try container.decodeIfPresent(String.self, forKey: .instructionText)
        transcriptionProvider = try container.decodeIfPresent(String.self, forKey: .transcriptionProvider)
        transcriptionModel = try container.decodeIfPresent(String.self, forKey: .transcriptionModel)
        rewriteProvider = try container.decodeIfPresent(String.self, forKey: .rewriteProvider)
        rewriteModel = try container.decodeIfPresent(String.self, forKey: .rewriteModel)
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
        try container.encodeIfPresent(instructionText, forKey: .instructionText)
        try container.encodeIfPresent(transcriptionProvider, forKey: .transcriptionProvider)
        try container.encodeIfPresent(transcriptionModel, forKey: .transcriptionModel)
        try container.encodeIfPresent(rewriteProvider, forKey: .rewriteProvider)
        try container.encodeIfPresent(rewriteModel, forKey: .rewriteModel)
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

@MainActor
final class LocalHistoryStore: ObservableObject {
    @Published private(set) var entries: [SessionHistoryEntry] = []

    private let fileURL: URL
    private let fileManager: FileManager
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder
    private let maxEntries: Int

    init(
        historyDirectory: URL,
        fileManager: FileManager = .default,
        maxEntries: Int = 3000
    ) {
        self.fileManager = fileManager
        self.fileURL = historyDirectory.appendingPathComponent("session-history-v1.json", isDirectory: false)
        self.maxEntries = maxEntries
        self.jsonDecoder = JSONDecoder()
        self.jsonDecoder.dateDecodingStrategy = .iso8601
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.dateEncodingStrategy = .iso8601
        self.jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        load()
    }

    func append(_ entry: SessionHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        persist()
    }

    func delete(entryID: UUID) {
        entries.removeAll { $0.id == entryID }
        persist()
    }

    func clearAll() {
        entries = []
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    func entries(matching filter: LocalHistoryFilter) -> [SessionHistoryEntry] {
        switch filter {
        case .all:
            return entries
        case .dictation:
            return entries.filter { $0.mode == .dictation }
        case .selectionRewrite:
            return entries.filter { $0.mode == .selectionRewrite }
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

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            entries = []
            return
        }

        guard
            let data = try? Data(contentsOf: fileURL),
            let loaded = try? jsonDecoder.decode([SessionHistoryEntry].self, from: data)
        else {
            entries = []
            return
        }

        entries = loaded.sorted(by: { $0.timestamp > $1.timestamp })
    }

    private func persist() {
        guard let data = try? jsonEncoder.encode(entries) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}

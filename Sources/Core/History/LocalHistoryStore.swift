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
        audioDurationSeconds: Double? = nil
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

    func todayStatistics(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HistoryStatisticsSnapshot {
        let todayEntries = entries.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
        guard !todayEntries.isEmpty else {
            return .zero
        }

        let totalDuration = todayEntries.reduce(0) { partial, entry in
            partial + max(0, entry.audioDurationSeconds ?? 0)
        }
        let totalCharacters = todayEntries.reduce(0) { partial, entry in
            let text = (entry.outputText ?? entry.inputText).trimmingCharacters(in: .whitespacesAndNewlines)
            return partial + text.count
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

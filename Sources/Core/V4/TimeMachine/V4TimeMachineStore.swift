import Foundation

actor V4TimeMachineStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder
    private var items: [V4TimeItem]

    init(
        historyDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = Self.storageURL(historyDirectory: historyDirectory)
        self.jsonEncoder = JSONEncoder()
        self.jsonDecoder = JSONDecoder()
        self.jsonEncoder.dateEncodingStrategy = .iso8601
        self.jsonDecoder.dateDecodingStrategy = .iso8601
        self.jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.items = Self.loadItems(fileURL: Self.storageURL(historyDirectory: historyDirectory), fileManager: fileManager)
    }

    func allItems() -> [V4TimeItem] {
        items.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id > rhs.id
        }
    }

    func save(_ item: V4TimeItem) throws {
        items.removeAll { $0.id == item.id }
        items.append(item)
        try persist()
    }

    static func storageURL(historyDirectory: URL) -> URL {
        historyDirectory.appendingPathComponent("time-machine-items-v1.json", isDirectory: false)
    }

    static func loadItems(
        historyDirectory: URL,
        fileManager: FileManager = .default
    ) -> [V4TimeItem] {
        loadItems(fileURL: storageURL(historyDirectory: historyDirectory), fileManager: fileManager)
    }

    static func loadItems(
        fileURL: URL,
        fileManager: FileManager = .default
    ) -> [V4TimeItem] {
        guard
            fileManager.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL)
        else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([V4TimeItem].self, from: data)) ?? []
    }

    private func persist() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try jsonEncoder.encode(allItems())
        try data.write(to: fileURL, options: .atomic)
    }
}

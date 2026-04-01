import Foundation

struct BrainstormDurationProfile: Codable, Equatable {
    static let fallbackMaxSeconds = 120
    static let fallbackRecommendedSeconds = 90

    let providerType: ProviderType
    let modelName: String
    let maxSeconds: Int
    let recommendedSeconds: Int
    let measuredAt: Date

    static func fallback(
        providerType: ProviderType,
        modelName: String,
        measuredAt: Date = Date()
    ) -> BrainstormDurationProfile {
        BrainstormDurationProfile(
            providerType: providerType,
            modelName: modelName,
            maxSeconds: fallbackMaxSeconds,
            recommendedSeconds: fallbackRecommendedSeconds,
            measuredAt: measuredAt
        )
    }
}

enum BrainstormDurationProbePlanner {
    static let coarseDurations: [Int] = [30, 60, 120, 180, 240, 300]
    static let precisionSeconds = 5

    static func recommendedSeconds(maxSeconds: Int) -> Int {
        let rounded = Int(floor(Double(maxSeconds) * 0.8 / Double(precisionSeconds))) * precisionSeconds
        return max(30, rounded)
    }

    static func resolveMaxSeconds(
        probe: (Int) async -> Bool
    ) async -> Int {
        var lowerBound = 0
        var firstFailureUpperBound: Int?

        for duration in coarseDurations {
            let success = await probe(duration)
            if success {
                lowerBound = duration
            } else {
                firstFailureUpperBound = duration
                break
            }
        }

        guard let initialUpperBound = firstFailureUpperBound else {
            return coarseDurations.last ?? lowerBound
        }

        var upperBound = initialUpperBound
        while upperBound - lowerBound > precisionSeconds {
            var middle = ((lowerBound + upperBound) / 2 / precisionSeconds) * precisionSeconds
            if middle <= lowerBound {
                middle = lowerBound + precisionSeconds
            }
            if middle >= upperBound {
                break
            }
            let success = await probe(middle)
            if success {
                lowerBound = middle
            } else {
                upperBound = middle
            }
        }

        return max(0, lowerBound)
    }
}

@MainActor
final class BrainstormDurationProfileStore: ObservableObject {
    @Published private(set) var profiles: [BrainstormDurationProfile] = []

    private let fileURL: URL
    private let fileManager: FileManager
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder

    init(
        historyDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = historyDirectory.appendingPathComponent(
            "brainstorm-duration-profiles-v1.json",
            isDirectory: false
        )
        self.jsonDecoder = JSONDecoder()
        self.jsonDecoder.dateDecodingStrategy = .iso8601
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.dateEncodingStrategy = .iso8601
        self.jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        load()
    }

    func profile(
        for providerType: ProviderType,
        modelName: String
    ) -> BrainstormDurationProfile? {
        let lookupKey = key(
            providerType: providerType,
            modelName: modelName
        )
        return profiles.first { profile in
            key(providerType: profile.providerType, modelName: profile.modelName) == lookupKey
        }
    }

    func effectiveProfile(
        for providerType: ProviderType,
        modelName: String,
        measuredAt: Date = Date()
    ) -> BrainstormDurationProfile {
        profile(for: providerType, modelName: modelName)
            ?? .fallback(
                providerType: providerType,
                modelName: modelName,
                measuredAt: measuredAt
            )
    }

    func hasFreshProfile(
        for providerType: ProviderType,
        modelName: String,
        now: Date = Date(),
        maxAge: TimeInterval = 24 * 60 * 60
    ) -> Bool {
        guard
            let profile = profile(for: providerType, modelName: modelName)
        else {
            return false
        }
        return now.timeIntervalSince(profile.measuredAt) <= maxAge
    }

    func upsert(_ profile: BrainstormDurationProfile) {
        let lookupKey = key(
            providerType: profile.providerType,
            modelName: profile.modelName
        )
        profiles.removeAll {
            key(providerType: $0.providerType, modelName: $0.modelName) == lookupKey
        }
        profiles.append(profile)
        profiles.sort { lhs, rhs in
            lhs.measuredAt > rhs.measuredAt
        }
        persist()
    }

    func clearAll() {
        profiles = []
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            profiles = []
            return
        }
        guard
            let data = try? Data(contentsOf: fileURL),
            let loaded = try? jsonDecoder.decode([BrainstormDurationProfile].self, from: data)
        else {
            profiles = []
            return
        }
        profiles = loaded.sorted(by: { $0.measuredAt > $1.measuredAt })
    }

    private func persist() {
        guard let data = try? jsonEncoder.encode(profiles) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func key(
        providerType: ProviderType,
        modelName: String
    ) -> String {
        let normalizedModel = modelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(providerType.rawValue)|\(normalizedModel)"
    }
}

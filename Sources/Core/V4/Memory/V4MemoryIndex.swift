import Foundation

enum V4MemorySearchField: String, CaseIterable, Codable, Sendable {
    case input
    case output
    case instruction
    case goal
    case steps
    case evidence
    case tags
}

struct V4MemoryPosting: Equatable, Sendable {
    let entryIndex: Int
    let field: V4MemorySearchField
    let occurrenceCount: Int
}

struct V4IndexedMemoryEntry: Equatable, Sendable {
    let entry: V4MemoryEntry
    let orderIndex: Int
    let tokensByField: [V4MemorySearchField: [String: Int]]
}

struct V4MemoryIndex: Equatable, Sendable {
    let entries: [V4IndexedMemoryEntry]
    let postings: [String: [V4MemoryPosting]]

    init(entries: [V4MemoryEntry]) {
        var indexedEntries: [V4IndexedMemoryEntry] = []
        var postingMap: [String: [V4MemoryPosting]] = [:]

        for (orderIndex, entry) in entries.enumerated() {
            let tokensByField = Self.tokensByField(for: entry)
            indexedEntries.append(
                V4IndexedMemoryEntry(
                    entry: entry,
                    orderIndex: orderIndex,
                    tokensByField: tokensByField
                )
            )

            for (field, tokenCounts) in tokensByField {
                for (token, count) in tokenCounts {
                    postingMap[token, default: []].append(
                        V4MemoryPosting(
                            entryIndex: orderIndex,
                            field: field,
                            occurrenceCount: count
                        )
                    )
                }
            }
        }

        self.entries = indexedEntries
        self.postings = postingMap
    }

    static func tokenize(_ text: String) -> [String] {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return []
        }

        var tokens = Set<String>()
        let nsRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)

        if let asciiRegex = try? NSRegularExpression(pattern: #"[a-z0-9][a-z0-9._-]*"#) {
            for match in asciiRegex.matches(in: normalized, range: nsRange) {
                guard let range = Range(match.range, in: normalized) else {
                    continue
                }
                let token = String(normalized[range])
                if !token.isEmpty {
                    tokens.insert(token)
                }
            }
        }

        if let cjkRegex = try? NSRegularExpression(pattern: #"\p{Han}+"#) {
            for match in cjkRegex.matches(in: normalized, range: nsRange) {
                guard let range = Range(match.range, in: normalized) else {
                    continue
                }
                let chunk = String(normalized[range])
                let characters = Array(chunk)
                guard !characters.isEmpty else {
                    continue
                }

                tokens.insert(chunk)

                for character in characters {
                    tokens.insert(String(character))
                }

                if characters.count > 1 {
                    let maxLength = min(4, characters.count)
                    for length in 2...maxLength {
                        for start in 0...(characters.count - length) {
                            let token = String(characters[start..<(start + length)])
                            tokens.insert(token)
                        }
                    }
                }
            }
        }

        return Array(tokens)
    }

    private static func tokensByField(for entry: V4MemoryEntry) -> [V4MemorySearchField: [String: Int]] {
        var values: [V4MemorySearchField: [String: Int]] = [:]
        values[.input] = tokenCounts(from: entry.inputText)
        values[.output] = tokenCounts(from: entry.outputText)
        values[.instruction] = tokenCounts(from: entry.instructionText)
        values[.goal] = tokenCounts(from: entry.goalSummary)
        values[.steps] = tokenCounts(from: entry.stepSummaries.joined(separator: "\n"))
        values[.evidence] = tokenCounts(from: entry.evidenceSummary)
        values[.tags] = tokenCounts(from: entry.moduleTags.joined(separator: " "))
        return values
    }

    private static func tokenCounts(from text: String) -> [String: Int] {
        tokenize(text).reduce(into: [:]) { partialResult, token in
            partialResult[token, default: 0] += 1
        }
    }
}

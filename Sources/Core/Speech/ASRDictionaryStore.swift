import Foundation

struct ASRDictionarySnapshot: Equatable {
    let effectiveTerms: [String]
    let injectedTerms: [String]
    let promptHintText: String
    let hotwordText: String
    let didTruncate: Bool
    let maxCharacters: Int

    var injectedCharacterCount: Int {
        promptHintText.count
    }
}

@MainActor
final class ASRDictionaryStore: ObservableObject {
    nonisolated static let defaultStorageKey = "asr.dictionary.v1"
    nonisolated static let defaultMaxPromptCharacters = 4000

    private nonisolated static let promptHeader = "用户词典（优先识别以下词条并按原样输出）："

    @Published private(set) var rawText: String

    private let defaults: UserDefaults
    private let storageKey: String
    private let maxPromptCharacters: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = ASRDictionaryStore.defaultStorageKey,
        maxPromptCharacters: Int = ASRDictionaryStore.defaultMaxPromptCharacters
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maxPromptCharacters = maxPromptCharacters

        let stored = defaults.string(forKey: storageKey) ?? ""
        rawText = Self.normalizeRawText(stored)
        persist()
    }

    var effectiveTerms: [String] {
        Self.parseTerms(from: rawText)
    }

    var promptHintText: String {
        currentSnapshot().promptHintText
    }

    var hotwordText: String {
        currentSnapshot().hotwordText
    }

    func currentSnapshot() -> ASRDictionarySnapshot {
        Self.buildSnapshot(
            rawText: rawText,
            maxCharacters: maxPromptCharacters
        )
    }

    func preview(rawText: String) -> ASRDictionarySnapshot {
        Self.buildSnapshot(
            rawText: rawText,
            maxCharacters: maxPromptCharacters
        )
    }

    @discardableResult
    func save(rawText: String) -> ASRDictionarySnapshot {
        self.rawText = Self.normalizeRawText(rawText)
        persist()
        return currentSnapshot()
    }

    private func persist() {
        defaults.set(rawText, forKey: storageKey)
    }

    private static func normalizeRawText(_ rawText: String) -> String {
        parseTerms(from: rawText).joined(separator: "\n")
    }

    fileprivate static func parseTerms(from rawText: String) -> [String] {
        let lines = rawText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var deduped: [String] = []
        var seen = Set<String>()
        for line in lines {
            let key = line.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            if seen.insert(key).inserted {
                deduped.append(line)
            }
        }
        return deduped
    }

    private static func buildSnapshot(
        rawText: String,
        maxCharacters: Int
    ) -> ASRDictionarySnapshot {
        let terms = parseTerms(from: rawText)
        guard !terms.isEmpty else {
            return ASRDictionarySnapshot(
                effectiveTerms: [],
                injectedTerms: [],
                promptHintText: "",
                hotwordText: "",
                didTruncate: false,
                maxCharacters: maxCharacters
            )
        }

        let header = "\(promptHeader)\n"
        let safeLimit = max(0, maxCharacters)

        var injectedTerms: [String] = []
        var currentLength = header.count
        for term in terms {
            let extra = injectedTerms.isEmpty ? term.count : term.count + 1
            if currentLength + extra > safeLimit {
                break
            }
            injectedTerms.append(term)
            currentLength += extra
        }

        if injectedTerms.isEmpty {
            return ASRDictionarySnapshot(
                effectiveTerms: terms,
                injectedTerms: [],
                promptHintText: "",
                hotwordText: "",
                didTruncate: true,
                maxCharacters: maxCharacters
            )
        }

        let termBlock = injectedTerms.joined(separator: "\n")
        return ASRDictionarySnapshot(
            effectiveTerms: terms,
            injectedTerms: injectedTerms,
            promptHintText: "\(header)\(termBlock)",
            hotwordText: termBlock,
            didTruncate: injectedTerms.count < terms.count,
            maxCharacters: maxCharacters
        )
    }
}

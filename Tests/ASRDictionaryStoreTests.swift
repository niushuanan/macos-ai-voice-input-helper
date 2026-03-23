import XCTest
@testable import PulseType

@MainActor
final class ASRDictionaryStoreTests: XCTestCase {
    func testParseRulesKeepPhrasesAndDeduplicateCaseInsensitive() throws {
        let defaults = try makeIsolatedDefaults()
        let store = ASRDictionaryStore(
            defaults: defaults,
            storageKey: "asr.dictionary.store.tests.parse"
        )

        let snapshot = store.save(
            rawText: """
              OpenAI

            deepseek
            DeepSeek
            semantic cache
            Semantic Cache
            Tensor RT
            """
        )

        XCTAssertEqual(
            snapshot.effectiveTerms,
            ["OpenAI", "deepseek", "semantic cache", "Tensor RT"]
        )
        XCTAssertEqual(store.rawText, "OpenAI\ndeepseek\nsemantic cache\nTensor RT")
        XCTAssertEqual(snapshot.hotwordText, "OpenAI\ndeepseek\nsemantic cache\nTensor RT")
        XCTAssertTrue(snapshot.promptHintText.contains("用户词典"))
        XCTAssertTrue(snapshot.promptHintText.contains("semantic cache"))
        XCTAssertFalse(snapshot.didTruncate)
    }

    func testSavePersistsToUserDefaults() throws {
        let defaults = try makeIsolatedDefaults()
        let key = "asr.dictionary.store.tests.persist"
        let first = ASRDictionaryStore(defaults: defaults, storageKey: key)
        _ = first.save(rawText: "OpenAI\nDeepSeek")

        let reloaded = ASRDictionaryStore(defaults: defaults, storageKey: key)
        XCTAssertEqual(reloaded.rawText, "OpenAI\nDeepSeek")
        XCTAssertEqual(reloaded.effectiveTerms, ["OpenAI", "DeepSeek"])
    }

    func testLongPromptAutomaticallyTruncates() throws {
        let defaults = try makeIsolatedDefaults()
        let store = ASRDictionaryStore(
            defaults: defaults,
            storageKey: "asr.dictionary.store.tests.long",
            maxPromptCharacters: 4000
        )

        let longTerms = (0..<120).map { index in
            "very-long-term-\(index)-" + String(repeating: "x", count: 60)
        }
        let snapshot = store.save(rawText: longTerms.joined(separator: "\n"))

        XCTAssertTrue(snapshot.didTruncate)
        XCTAssertLessThan(snapshot.injectedTerms.count, snapshot.effectiveTerms.count)
        XCTAssertLessThanOrEqual(snapshot.injectedCharacterCount, 4000)
        XCTAssertFalse(snapshot.promptHintText.isEmpty)
    }

    func testWhenFirstTermExceedsLimitSnapshotFallsBackGracefully() throws {
        let defaults = try makeIsolatedDefaults()
        let store = ASRDictionaryStore(
            defaults: defaults,
            storageKey: "asr.dictionary.store.tests.first-too-long",
            maxPromptCharacters: 12
        )

        let snapshot = store.save(rawText: String(repeating: "a", count: 100))
        XCTAssertTrue(snapshot.didTruncate)
        XCTAssertTrue(snapshot.injectedTerms.isEmpty)
        XCTAssertEqual(snapshot.promptHintText, "")
        XCTAssertEqual(snapshot.hotwordText, "")
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "ASRDictionaryStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "ASRDictionaryStoreTests", code: 1)
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

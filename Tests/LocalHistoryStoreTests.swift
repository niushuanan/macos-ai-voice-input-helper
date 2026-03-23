import Foundation
import XCTest
@testable import PulseType

@MainActor
final class LocalHistoryStoreTests: XCTestCase {
    func testEntriesFilterByModeAndFailureStatus() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.append(
            makeEntry(
                timestamp: Date(timeIntervalSince1970: 1_762_000_000),
                mode: .dictation,
                status: .success,
                inputText: "dictation-success",
                outputText: "dictation-success"
            )
        )
        store.append(
            makeEntry(
                timestamp: Date(timeIntervalSince1970: 1_762_000_010),
                mode: .selectionRewrite,
                status: .success,
                inputText: "rewrite-success",
                outputText: "rewrite-success"
            )
        )
        store.append(
            makeEntry(
                timestamp: Date(timeIntervalSince1970: 1_762_000_020),
                mode: .dictation,
                status: .failed,
                inputText: "dictation-failed",
                outputText: nil,
                errorMessage: "network"
            )
        )
        store.append(
            makeEntry(
                timestamp: Date(timeIntervalSince1970: 1_762_000_030),
                mode: .brainstorm,
                status: .success,
                inputText: "brainstorm-raw",
                outputText: "brainstorm-final"
            )
        )

        XCTAssertEqual(store.entries(matching: .all).count, 4)
        XCTAssertEqual(store.entries(matching: .dictation).count, 2)
        XCTAssertEqual(store.entries(matching: .selectionRewrite).count, 1)
        XCTAssertEqual(store.entries(matching: .brainstorm).count, 1)
        XCTAssertEqual(store.entries(matching: .failed).count, 1)
    }

    func testLifetimeStatisticsCountOnlySuccessfulDictation() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.append(
            makeEntry(
                mode: .dictation,
                status: .success,
                inputText: "hello",
                outputText: "hello",
                audioDurationSeconds: 30
            )
        )
        store.append(
            makeEntry(
                mode: .dictation,
                status: .failed,
                inputText: "should-not-count",
                outputText: nil,
                audioDurationSeconds: 40
            )
        )
        store.append(
            makeEntry(
                mode: .selectionRewrite,
                status: .success,
                inputText: "rewrite",
                outputText: "rewrite",
                audioDurationSeconds: 50
            )
        )
        store.append(
            makeEntry(
                mode: .dictation,
                status: .cancelled,
                inputText: "cancelled",
                outputText: nil,
                audioDurationSeconds: 10
            )
        )

        let snapshot = store.lifetimeStatistics()
        XCTAssertEqual(snapshot.totalDialogueDurationSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(snapshot.totalInputCharacters, 5)
        XCTAssertEqual(snapshot.averageCharactersPerMinute, 10, accuracy: 0.001)
    }

    func testLifetimeStatisticsEstimateDurationForLegacyRowsWithoutAudioDuration() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.append(
            makeEntry(
                mode: .dictation,
                status: .success,
                inputText: "12345678",
                outputText: nil,
                audioDurationSeconds: nil
            )
        )

        let snapshot = store.lifetimeStatistics()
        XCTAssertEqual(snapshot.totalInputCharacters, 8)
        XCTAssertEqual(snapshot.totalDialogueDurationSeconds, 2.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageCharactersPerMinute, 240, accuracy: 0.001)
        XCTAssertEqual(snapshot.savedTypingSeconds, 6, accuracy: 0.001)
    }

    func testLifetimeStatisticsUsesFullTextWithoutUITruncation() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let longText = String(repeating: "长", count: 600) + String(repeating: "A", count: 400)
        store.append(
            makeEntry(
                mode: .dictation,
                status: .success,
                inputText: "ignored",
                outputText: longText,
                audioDurationSeconds: 120
            )
        )

        let snapshot = store.lifetimeStatistics()
        XCTAssertEqual(snapshot.totalInputCharacters, longText.count)
        XCTAssertEqual(snapshot.totalDialogueDurationSeconds, 120, accuracy: 0.001)
    }

    func testMigrationRecalculatesLifetimeFromLegacyEntriesFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-migration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyEntries: [SessionHistoryEntry] = [
            makeEntry(
                timestamp: Date(timeIntervalSince1970: 1_762_100_000),
                mode: .dictation,
                status: .success,
                inputText: "abcdefghij",
                outputText: "abcdefghij",
                audioDurationSeconds: 20
            ),
            makeEntry(
                timestamp: Date(timeIntervalSince1970: 1_762_100_010),
                mode: .dictation,
                status: .success,
                inputText: "12345",
                outputText: nil,
                audioDurationSeconds: nil
            ),
            makeEntry(
                timestamp: Date(timeIntervalSince1970: 1_762_100_020),
                mode: .dictation,
                status: .failed,
                inputText: "ignored",
                outputText: nil,
                audioDurationSeconds: 12
            )
        ]

        let legacyFileURL = directory.appendingPathComponent("session-history-v1.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(legacyEntries)
        try data.write(to: legacyFileURL, options: .atomic)

        let store = LocalHistoryStore(historyDirectory: directory)
        let snapshot = store.lifetimeStatistics()

        XCTAssertEqual(snapshot.totalInputCharacters, 15)
        XCTAssertEqual(snapshot.totalDialogueDurationSeconds, 21.25, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageCharactersPerMinute, 42.35, accuracy: 0.01)
        XCTAssertEqual(snapshot.savedTypingSeconds, 0, accuracy: 0.001)

        let lifetimeFileURL = directory.appendingPathComponent("lifetime-stats-v1.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lifetimeFileURL.path))
    }

    func testLoadingLegacyLifetimeSnapshotRecalculatesSavedSecondsWithNewBaseline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-lifetime-baseline-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let entries: [SessionHistoryEntry] = [
            makeEntry(
                mode: .dictation,
                status: .success,
                inputText: "12345678",
                outputText: nil,
                audioDurationSeconds: 2
            )
        ]
        try encoder.encode(entries).write(
            to: directory.appendingPathComponent("session-history-v1.json", isDirectory: false),
            options: .atomic
        )

        let oldBaselineSnapshot = HistoryLifetimeSnapshot(
            totalDialogueDurationSeconds: 2,
            totalInputCharacters: 8,
            averageCharactersPerMinute: 240,
            savedTypingSeconds: 0.4
        )
        try encoder.encode(oldBaselineSnapshot).write(
            to: directory.appendingPathComponent("lifetime-stats-v1.json", isDirectory: false),
            options: .atomic
        )

        let store = LocalHistoryStore(historyDirectory: directory)
        let snapshot = store.lifetimeStatistics()
        XCTAssertEqual(snapshot.savedTypingSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(snapshot.totalInputCharacters, 8)
        XCTAssertEqual(snapshot.totalDialogueDurationSeconds, 2, accuracy: 0.001)
    }

    func testDeleteDoesNotChangeLifetimeStatistics() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = makeEntry(
            mode: .dictation,
            status: .success,
            inputText: "12345",
            outputText: "12345",
            audioDurationSeconds: 10
        )
        let second = makeEntry(
            mode: .dictation,
            status: .success,
            inputText: "abcdef",
            outputText: "abcdef",
            audioDurationSeconds: 12
        )

        store.append(first)
        store.append(second)
        let before = store.lifetimeStatistics()

        store.delete(entryID: first.id)
        let after = store.lifetimeStatistics()

        XCTAssertEqual(before, after)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testClearAllDoesNotChangeLifetimeStatistics() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.append(
            makeEntry(
                mode: .dictation,
                status: .success,
                inputText: "abcdefghij",
                outputText: "abcdefghij",
                audioDurationSeconds: 20
            )
        )

        let before = store.lifetimeStatistics()
        store.clearAll()
        let after = store.lifetimeStatistics()

        XCTAssertEqual(before, after)
        XCTAssertTrue(store.entries.isEmpty)
    }

    private func makeStore() -> (LocalHistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (LocalHistoryStore(historyDirectory: directory), directory)
    }

    private func makeEntry(
        timestamp: Date = Date(timeIntervalSince1970: 1_762_000_000),
        mode: SessionHistoryMode,
        status: SessionHistoryStatus,
        inputText: String,
        outputText: String?,
        errorMessage: String? = nil,
        audioDurationSeconds: Double? = nil
    ) -> SessionHistoryEntry {
        SessionHistoryEntry(
            timestamp: timestamp,
            mode: mode,
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            inputText: inputText,
            outputText: outputText,
            status: status,
            errorMessage: errorMessage,
            audioDurationSeconds: audioDurationSeconds
        )
    }
}

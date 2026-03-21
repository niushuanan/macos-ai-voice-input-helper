import XCTest
@testable import PulseType

@MainActor
final class LocalHistoryStoreTests: XCTestCase {
    func testEntriesFilterByModeAndFailureStatus() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.append(
            SessionHistoryEntry(
                timestamp: Date(timeIntervalSince1970: 1_762_000_000),
                mode: .dictation,
                appName: "TextEdit",
                bundleID: "com.apple.TextEdit",
                inputText: "dictation-success",
                outputText: "dictation-success",
                status: .success
            )
        )
        store.append(
            SessionHistoryEntry(
                timestamp: Date(timeIntervalSince1970: 1_762_000_010),
                mode: .selectionRewrite,
                appName: "Notes",
                bundleID: "com.apple.Notes",
                inputText: "rewrite-success",
                outputText: "rewrite-success",
                status: .success
            )
        )
        store.append(
            SessionHistoryEntry(
                timestamp: Date(timeIntervalSince1970: 1_762_000_020),
                mode: .dictation,
                appName: "Slack",
                bundleID: "com.tinyspeck.slackmacgap",
                inputText: "dictation-failed",
                outputText: nil,
                status: .failed,
                errorMessage: "network"
            )
        )

        XCTAssertEqual(store.entries(matching: .all).count, 3)
        XCTAssertEqual(store.entries(matching: .dictation).count, 2)
        XCTAssertEqual(store.entries(matching: .selectionRewrite).count, 1)
        XCTAssertEqual(store.entries(matching: .failed).count, 1)
    }

    func testTodayStatisticsUsesTodayEntriesOnly() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_762_000_100)
        let yesterday = now.addingTimeInterval(-86_400)

        store.append(
            SessionHistoryEntry(
                timestamp: now.addingTimeInterval(-30),
                mode: .dictation,
                appName: "TextEdit",
                bundleID: "com.apple.TextEdit",
                inputText: "hello",
                outputText: "hello",
                status: .success,
                audioDurationSeconds: 30
            )
        )
        store.append(
            SessionHistoryEntry(
                timestamp: now.addingTimeInterval(-10),
                mode: .dictation,
                appName: "TextEdit",
                bundleID: "com.apple.TextEdit",
                inputText: "swift",
                outputText: nil,
                status: .success,
                audioDurationSeconds: 90
            )
        )
        store.append(
            SessionHistoryEntry(
                timestamp: yesterday,
                mode: .dictation,
                appName: "TextEdit",
                bundleID: "com.apple.TextEdit",
                inputText: "ignored",
                outputText: "ignored",
                status: .success,
                audioDurationSeconds: 60
            )
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        let snapshot = store.todayStatistics(now: now, calendar: calendar)

        XCTAssertEqual(snapshot.totalDurationSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(snapshot.totalCharacters, 10)
        XCTAssertEqual(snapshot.charactersPerMinute, 5, accuracy: 0.001)
    }

    private func makeStore() -> (LocalHistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (LocalHistoryStore(historyDirectory: directory), directory)
    }
}

import XCTest
@testable import PulseType

@MainActor
final class ControlCenterStateTests: XCTestCase {
    func testHomeStatsSnapshotTracksLifetimeStatistics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-center-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LocalHistoryStore(historyDirectory: directory)
        let state = ControlCenterState(localHistoryStore: store)

        XCTAssertEqual(state.homeStatsSnapshot, .zero)

        store.append(
            SessionHistoryEntry(
                mode: .dictation,
                appName: "TextEdit",
                bundleID: "com.apple.TextEdit",
                inputText: "hello",
                outputText: "hello",
                status: .success,
                audioDurationSeconds: 30
            )
        )

        XCTAssertEqual(state.homeStatsSnapshot.totalInputCharacters, 5)
        XCTAssertEqual(state.homeStatsSnapshot.totalDialogueDurationSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(state.homeStatsSnapshot.averageCharactersPerMinute, 10, accuracy: 0.001)

        store.append(
            SessionHistoryEntry(
                mode: .dictation,
                appName: "TextEdit",
                bundleID: "com.apple.TextEdit",
                inputText: "ignored",
                outputText: nil,
                status: .failed,
                audioDurationSeconds: 10
            )
        )

        XCTAssertEqual(state.homeStatsSnapshot.totalInputCharacters, 5)
        XCTAssertEqual(state.homeStatsSnapshot.totalDialogueDurationSeconds, 30, accuracy: 0.001)
    }
}

import XCTest
@testable import PulseType

@MainActor
final class ControlCenterStateTests: XCTestCase {
    func testDesktopSectionIncludesMagician() {
        XCTAssertTrue(DesktopSection.allCases.contains(.magician))
        XCTAssertEqual(DesktopSection.magician.title, "魔术先生")
        XCTAssertEqual(DesktopSection.magician.symbolName, "wand.and.stars")
        XCTAssertEqual(DesktopSection.agentBrainstorm.title, "一口气全念对")
    }

    func testDesktopSectionOrderMatchesSidebarDesign() {
        XCTAssertEqual(
            DesktopSection.allCases,
            [.home, .memory, .dictionary, .skills, .model, .magician, .agentBrainstorm, .settings]
        )
    }

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
        XCTAssertEqual(state.homeStatsSnapshot.speedSampleCount, 1)

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

        store.append(
            SessionHistoryEntry(
                mode: .dictation,
                appName: "TextEdit",
                bundleID: "com.apple.TextEdit",
                inputText: "legacy",
                outputText: "legacy",
                status: .success,
                audioDurationSeconds: nil
            )
        )

        XCTAssertEqual(state.homeStatsSnapshot.totalInputCharacters, 11)
        XCTAssertEqual(state.homeStatsSnapshot.totalDialogueDurationSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(state.homeStatsSnapshot.speedSampleCount, 1)
    }
}

import XCTest
@testable import PulseType

final class HomeStatsFormatterTests: XCTestCase {
    func testSpeedTextShowsDashWhenNoRealDurationSample() {
        let snapshot = HistoryLifetimeSnapshot(
            totalDialogueDurationSeconds: 0,
            totalInputCharacters: 120,
            averageCharactersPerMinute: 0,
            savedTypingSeconds: 0,
            speedSampleCount: 0
        )

        XCTAssertEqual(HomeStatsFormatter.speedText(snapshot: snapshot), "—")
    }

    func testSpeedTextShowsRoundedValueWhenSamplesExist() {
        let snapshot = HistoryLifetimeSnapshot(
            totalDialogueDurationSeconds: 30,
            totalInputCharacters: 120,
            averageCharactersPerMinute: 87.6,
            savedTypingSeconds: 0,
            speedSampleCount: 2
        )

        XCTAssertEqual(HomeStatsFormatter.speedText(snapshot: snapshot), "88")
    }
}

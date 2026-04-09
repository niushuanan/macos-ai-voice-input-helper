import XCTest
@testable import PulseType

@MainActor
final class MusicFastExecutorTests: XCTestCase {
    func testMatchesRequestedTrackAcceptsArtistSongVariant() {
        XCTAssertTrue(
            MusicFastExecutor.matchesRequestedTrack(
                requestedTrack: "播放周杰伦的《稻香》",
                resolvedTrack: "稻香",
                resolvedArtist: "周杰伦",
                evidenceSummary: "apple.music.control|track=稻香|artist=周杰伦|state=play"
            )
        )
    }

    func testMatchesRequestedTrackRejectsRequestedTrackOnlyEvidence() {
        XCTAssertFalse(
            MusicFastExecutor.matchesRequestedTrack(
                requestedTrack: "播放稻香",
                resolvedTrack: nil,
                resolvedArtist: nil,
                evidenceSummary: "apple.music.control|requested_track=稻香|playback_state=play|evidence_confidence=low"
            )
        )
    }
}

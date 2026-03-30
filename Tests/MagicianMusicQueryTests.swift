import XCTest
@testable import PulseType

final class MagicianMusicQueryTests: XCTestCase {
    func testSearchQueriesSplitArtistAndSong() {
        let queries = magicianMusicSearchQueries(from: "播放周杰伦的《稻香》")

        XCTAssertEqual(queries.first, "周杰伦的稻香")
        XCTAssertTrue(queries.contains("稻香"))
        XCTAssertTrue(queries.contains("周杰伦"))
    }

    func testSearchQueriesDeduplicateAndTrim() {
        let queries = magicianMusicSearchQueries(from: "  播放   稻香  ")

        XCTAssertEqual(queries, ["稻香"])
    }

    func testEvidenceMatchAcceptsQueryWithActionTokens() {
        XCTAssertTrue(
            magicianMusicEvidenceMatchesQuery(
                output: "track=稻香|artist=周杰伦",
                query: "播放周杰伦的稻香"
            )
        )
    }

    func testEvidenceMatchRejectsUnrelatedTrack() {
        XCTAssertFalse(
            magicianMusicEvidenceMatchesQuery(
                output: "track=七里香|artist=周杰伦",
                query: "播放周杰伦的稻香"
            )
        )
    }
}

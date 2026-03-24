import XCTest
@testable import PulseType

final class BrainstormDurationProbePlannerTests: XCTestCase {
    func testResolveMaxSecondsWithStableBoundary() async {
        let max = await BrainstormDurationProbePlanner.resolveMaxSeconds { seconds in
            seconds <= 175
        }
        XCTAssertEqual(max, 175)
    }

    func testResolveMaxSecondsWhenAllCoarseDurationsSucceed() async {
        let max = await BrainstormDurationProbePlanner.resolveMaxSeconds { _ in
            true
        }
        XCTAssertEqual(max, 300)
    }

    func testResolveMaxSecondsWhenFirstProbeFails() async {
        let max = await BrainstormDurationProbePlanner.resolveMaxSeconds { _ in
            false
        }
        XCTAssertEqual(max, 0)
    }

    func testRecommendedSecondsFollowsFormula() {
        XCTAssertEqual(
            BrainstormDurationProbePlanner.recommendedSeconds(maxSeconds: 175),
            140
        )
        XCTAssertEqual(
            BrainstormDurationProbePlanner.recommendedSeconds(maxSeconds: 0),
            30
        )
    }
}

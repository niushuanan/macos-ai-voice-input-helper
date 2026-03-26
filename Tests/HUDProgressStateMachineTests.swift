import XCTest
@testable import PulseType

final class HUDProgressStateMachineTests: XCTestCase {
    func testTranscribingStartsFromBaselineAndCap() {
        var machine = HUDProgressStateMachine()

        let frame = machine.transition(to: .transcribing)

        XCTAssertEqual(frame.progress, 0.12, accuracy: 0.0001)
        XCTAssertEqual(machine.cap, 0.46, accuracy: 0.0001)
        XCTAssertTrue(frame.visibility.keepVisible)

        guard case let .processing(title) = frame.style else {
            return XCTFail("expected processing style")
        }
        XCTAssertEqual(title, "转写中")
    }

    func testPhaseJumpToInsertingRaisesProgressBaseline() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(to: .transcribing)
        _ = machine.tick()

        let frame = machine.transition(to: .inserting)

        XCTAssertGreaterThanOrEqual(frame.progress, 0.78)
        XCTAssertEqual(machine.cap, 0.94, accuracy: 0.0001)
        guard case let .processing(title) = frame.style else {
            return XCTFail("expected processing style")
        }
        XCTAssertEqual(title, "写入中")
    }

    func testRewritingUsesMagicianFallbackTitle() {
        var machine = HUDProgressStateMachine()

        let frame = machine.transition(to: .rewriting)

        guard case let .processing(title) = frame.style else {
            return XCTFail("expected processing style")
        }
        XCTAssertEqual(title, "魔法师执行")
    }

    func testIdleAfterBusyEntersCompletionAndSchedulesQuickHide() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(to: .transcribing)
        _ = machine.transition(to: .inserting)

        let frame = machine.transition(to: .idle)

        XCTAssertEqual(frame.style, .completion)
        XCTAssertEqual(frame.progress, 1.0, accuracy: 0.0001)
        XCTAssertFalse(frame.visibility.keepVisible)
        XCTAssertEqual(frame.visibility.hideDelay, 0.26, accuracy: 0.0001)
        XCTAssertEqual(frame.visibility.fadeDuration, 0.12, accuracy: 0.0001)
    }

    func testCancelledAndErrorUseExpectedHideDurations() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(to: .listening)

        let cancelled = machine.transition(to: .cancelled)
        XCTAssertEqual(cancelled.style, .cancelled)
        XCTAssertEqual(cancelled.visibility.hideDelay, 0.46, accuracy: 0.0001)
        XCTAssertEqual(cancelled.visibility.fadeDuration, 0.12, accuracy: 0.0001)

        let error = machine.transition(to: .error)
        XCTAssertEqual(error.style, .error)
        XCTAssertEqual(error.visibility.hideDelay, 0.90, accuracy: 0.0001)
        XCTAssertEqual(error.visibility.fadeDuration, 0.12, accuracy: 0.0001)
    }

    func testTickSmoothlyApproachesCapWithoutOvershoot() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(to: .transcribing)

        let first = machine.progress
        let second = machine.tick()
        XCTAssertGreaterThan(second, first)

        for _ in 0..<200 {
            _ = machine.tick()
        }

        XCTAssertLessThanOrEqual(machine.progress, 0.46)
        XCTAssertEqual(machine.progress, 0.46, accuracy: 0.001)
    }
}

import Foundation
import KeyboardShortcuts
import XCTest
@testable import PulseType

final class GlobalHotkeyStateMachineTests: XCTestCase {
    func testModifierDoubleTapTriggersWhenSecondTapWithinWindow() {
        var stateMachine = ModifierDoubleTapStateMachine(interval: 0.35)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

        assertWaitingSecondTap(stateMachine.registerTap(at: t0))
        assertTrigger(stateMachine.registerTap(at: t0.addingTimeInterval(0.2)))
        XCTAssertNil(stateMachine.firstTapAt)
    }

    func testModifierDoubleTapBoundaryAtPointThreeFiveSecondsTriggers() {
        var stateMachine = ModifierDoubleTapStateMachine(interval: 0.35)
        let t0 = Date(timeIntervalSinceReferenceDate: 2_000)

        assertWaitingSecondTap(stateMachine.registerTap(at: t0))
        assertTrigger(stateMachine.registerTap(at: t0.addingTimeInterval(0.35)))
    }

    func testModifierDoubleTapSingleTapPathClearsAfterWindow() {
        var stateMachine = ModifierDoubleTapStateMachine(interval: 0.35)
        let t0 = Date(timeIntervalSinceReferenceDate: 3_000)

        assertWaitingSecondTap(stateMachine.registerTap(at: t0))
        XCTAssertTrue(stateMachine.clearIfExpired(at: t0.addingTimeInterval(0.35)))
        assertWaitingSecondTap(stateMachine.registerTap(at: t0.addingTimeInterval(0.36)))
    }

    func testBrainstormSequenceTriggersOnMatchingTwoStep() {
        var stateMachine = BrainstormSequenceStateMachine()

        assertNone(stateMachine.handleKey(.a, first: .a, second: .b))
        assertWaitingSecond(stateMachine.progress)
        assertTrigger(stateMachine.handleKey(.b, first: .a, second: .b))
        assertWaitingFirst(stateMachine.progress)
    }

    func testBrainstormSequenceWrongSecondKeyResetsState() {
        var stateMachine = BrainstormSequenceStateMachine()

        assertNone(stateMachine.handleKey(.a, first: .a, second: .b))
        assertNone(stateMachine.handleKey(.c, first: .a, second: .b))
        assertWaitingFirst(stateMachine.progress)
    }

    func testBrainstormSequenceHasNoTimeoutAndStillTriggers() {
        var stateMachine = BrainstormSequenceStateMachine()

        assertNone(stateMachine.handleKey(.a, first: .a, second: .b))
        // 状态机不依赖时间，隔很久后第二步仍可触发。
        assertTrigger(stateMachine.handleKey(.b, first: .a, second: .b))
    }

    private func assertWaitingSecondTap(_ action: ModifierDoubleTapAction, file: StaticString = #filePath, line: UInt = #line) {
        switch action {
        case .waitingSecondTap:
            break
        case .trigger:
            XCTFail("Expected waitingSecondTap, got trigger", file: file, line: line)
        }
    }

    private func assertTrigger(_ action: ModifierDoubleTapAction, file: StaticString = #filePath, line: UInt = #line) {
        switch action {
        case .trigger:
            break
        case .waitingSecondTap:
            XCTFail("Expected trigger, got waitingSecondTap", file: file, line: line)
        }
    }

    private func assertNone(_ action: BrainstormSequenceAction, file: StaticString = #filePath, line: UInt = #line) {
        switch action {
        case .none:
            break
        case .trigger:
            XCTFail("Expected none, got trigger", file: file, line: line)
        }
    }

    private func assertTrigger(_ action: BrainstormSequenceAction, file: StaticString = #filePath, line: UInt = #line) {
        switch action {
        case .trigger:
            break
        case .none:
            XCTFail("Expected trigger, got none", file: file, line: line)
        }
    }

    private func assertWaitingFirst(_ progress: BrainstormSequenceProgress, file: StaticString = #filePath, line: UInt = #line) {
        switch progress {
        case .waitingFirst:
            break
        case .waitingSecond:
            XCTFail("Expected waitingFirst, got waitingSecond", file: file, line: line)
        }
    }

    private func assertWaitingSecond(_ progress: BrainstormSequenceProgress, file: StaticString = #filePath, line: UInt = #line) {
        switch progress {
        case .waitingSecond:
            break
        case .waitingFirst:
            XCTFail("Expected waitingSecond, got waitingFirst", file: file, line: line)
        }
    }
}

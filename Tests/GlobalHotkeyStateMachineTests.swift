import Foundation
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
}

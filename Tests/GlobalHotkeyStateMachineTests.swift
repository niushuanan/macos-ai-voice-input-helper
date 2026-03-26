import Foundation
import XCTest
@testable import PulseType

final class GlobalHotkeyStateMachineTests: XCTestCase {
    func testWakeHoldBeginsAtThreshold() {
        var stateMachine = WakeModifierPressStateMachine(
            holdInterval: 0.18,
            tapInterval: 0.7
        )
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

        stateMachine.beginPress(at: t0, hasForeignInput: false)
        assertNoWakeAction(stateMachine.evaluateHold(at: t0.addingTimeInterval(0.179)))
        assertHoldBegan(stateMachine.evaluateHold(at: t0.addingTimeInterval(0.18)))
    }

    func testWakeHoldReleaseEmitsHoldEnded() {
        var stateMachine = WakeModifierPressStateMachine(
            holdInterval: 0.18,
            tapInterval: 0.7
        )
        let t0 = Date(timeIntervalSinceReferenceDate: 1_200)

        stateMachine.beginPress(at: t0, hasForeignInput: false)
        assertHoldBegan(stateMachine.evaluateHold(at: t0.addingTimeInterval(0.2)))
        assertHoldEnded(
            stateMachine.endPress(
                at: t0.addingTimeInterval(0.25),
                hasOtherModifierFamilies: false,
                sameFamilyStillPressed: false
            )
        )
    }

    func testWakeQuickTapRemainsTap() {
        var stateMachine = WakeModifierPressStateMachine(
            holdInterval: 0.18,
            tapInterval: 0.7
        )
        let t0 = Date(timeIntervalSinceReferenceDate: 1_400)

        stateMachine.beginPress(at: t0, hasForeignInput: false)
        assertTap(
            stateMachine.endPress(
                at: t0.addingTimeInterval(0.12),
                hasOtherModifierFamilies: false,
                sameFamilyStillPressed: false
            )
        )
    }

    func testWakeTapSuppressedAfterForeignInput() {
        var stateMachine = WakeModifierPressStateMachine(
            holdInterval: 0.18,
            tapInterval: 0.7
        )
        let t0 = Date(timeIntervalSinceReferenceDate: 1_600)

        stateMachine.beginPress(at: t0, hasForeignInput: false)
        stateMachine.registerForeignInput()
        assertNoWakeAction(
            stateMachine.endPress(
                at: t0.addingTimeInterval(0.1),
                hasOtherModifierFamilies: false,
                sameFamilyStillPressed: false
            )
        )
    }

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

    func testSameKeyHoldPathDoesNotFeedDoubleTapTrigger() {
        var wakeMachine = WakeModifierPressStateMachine(
            holdInterval: 0.18,
            tapInterval: 0.7
        )
        var doubleTap = ModifierDoubleTapStateMachine(interval: 0.35)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_800)

        wakeMachine.beginPress(at: t0, hasForeignInput: false)
        assertHoldBegan(wakeMachine.evaluateHold(at: t0.addingTimeInterval(0.2)))
        let releaseAction = wakeMachine.endPress(
            at: t0.addingTimeInterval(0.25),
            hasOtherModifierFamilies: false,
            sameFamilyStillPressed: false
        )
        assertHoldEnded(releaseAction)

        if case .tap = releaseAction {
            _ = doubleTap.registerTap(at: t0.addingTimeInterval(0.25))
        }
        XCTAssertNil(doubleTap.firstTapAt)
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

    private func assertNoWakeAction(
        _ action: WakeModifierPressAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch action {
        case .none:
            break
        case .tap, .holdBegan, .holdEnded:
            XCTFail("Expected none, got \(action)", file: file, line: line)
        }
    }

    private func assertTap(
        _ action: WakeModifierPressAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch action {
        case .tap:
            break
        case .none, .holdBegan, .holdEnded:
            XCTFail("Expected tap, got \(action)", file: file, line: line)
        }
    }

    private func assertHoldBegan(
        _ action: WakeModifierPressAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch action {
        case .holdBegan:
            break
        case .none, .tap, .holdEnded:
            XCTFail("Expected holdBegan, got \(action)", file: file, line: line)
        }
    }

    private func assertHoldEnded(
        _ action: WakeModifierPressAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch action {
        case .holdEnded:
            break
        case .none, .tap, .holdBegan:
            XCTFail("Expected holdEnded, got \(action)", file: file, line: line)
        }
    }
}

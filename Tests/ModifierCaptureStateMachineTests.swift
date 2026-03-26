import XCTest
@testable import PulseType

final class ModifierCaptureStateMachineTests: XCTestCase {
    func testStartProvidesInitialHint() {
        let state = ModifierCaptureStateMachine.start()

        XCTAssertNil(state.pendingModifier)
        XCTAssertEqual(state.hint, "请按左/右修饰键，然后按 Enter 确认。")
    }

    func testFlagsChangedCapturesModifierAndUpdatesHint() {
        var state = ModifierCaptureStateMachine.start()

        state.applyFlagsChanged(keyCode: HotkeyModifier.rightShift.keyCode)

        XCTAssertEqual(state.pendingModifier, .rightShift)
        XCTAssertEqual(state.hint, "已捕获 右 Shift。按 Enter 确认，按 Esc 取消。")
    }

    func testEnterWithoutModifierKeepsPrompting() {
        var state = ModifierCaptureStateMachine.start()

        let action = state.handleKeyDown(keyCode: 36)

        XCTAssertEqual(action, .none)
        XCTAssertEqual(state.hint, "还没有捕获到修饰键，请先按目标键。")
    }

    func testEnterAfterCaptureConfirmsModifier() {
        var state = ModifierCaptureStateMachine.start()
        state.applyFlagsChanged(keyCode: HotkeyModifier.leftOption.keyCode)

        let action = state.handleKeyDown(keyCode: 76)

        XCTAssertEqual(action, .confirm(.leftOption))
    }

    func testEscapeCancelsCapture() {
        var state = ModifierCaptureStateMachine.start()
        state.applyFlagsChanged(keyCode: HotkeyModifier.leftCommand.keyCode)

        XCTAssertEqual(state.handleKeyDown(keyCode: 53), .cancel)
    }
}

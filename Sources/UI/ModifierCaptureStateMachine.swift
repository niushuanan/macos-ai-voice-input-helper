import Foundation

enum ModifierCaptureKeyAction: Equatable {
    case none
    case confirm(HotkeyModifier)
    case cancel
}

struct ModifierCaptureStateMachine: Equatable {
    var pendingModifier: HotkeyModifier?
    var hint: String

    static func start() -> ModifierCaptureStateMachine {
        ModifierCaptureStateMachine(
            pendingModifier: nil,
            hint: "请按左/右修饰键，然后按 Enter 确认。"
        )
    }

    mutating func applyFlagsChanged(keyCode: UInt16) {
        guard let modifier = HotkeyModifier.from(keyCode: keyCode) else {
            return
        }
        pendingModifier = modifier
        hint = Self.confirmHint(for: modifier)
    }

    mutating func handleKeyDown(keyCode: UInt16) -> ModifierCaptureKeyAction {
        switch keyCode {
        case 36, 76:
            guard let pendingModifier else {
                hint = "还没有捕获到修饰键，请先按目标键。"
                return .none
            }
            return .confirm(pendingModifier)
        case 53:
            return .cancel
        default:
            if let pendingModifier {
                hint = Self.confirmHint(for: pendingModifier)
            } else {
                hint = "请先按目标修饰键，再按 Enter。"
            }
            return .none
        }
    }

    private static func confirmHint(for modifier: HotkeyModifier) -> String {
        "已捕获 \(modifier.displayName)。按 Enter 确认，按 Esc 取消。"
    }
}

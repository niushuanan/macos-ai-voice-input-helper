import Foundation

struct HotkeyDescriptor: Identifiable {
    let id: String
    let name: String
    let trigger: String
}

struct HotkeyCoordinator {
    let wakeShortcut: HotkeyDescriptor
    let stopShortcut: HotkeyDescriptor
    let cancelShortcut: HotkeyDescriptor
    let rewriteModifierHint: HotkeyDescriptor

    static let defaultConfiguration = HotkeyCoordinator(
        wakeShortcut: HotkeyDescriptor(
            id: "wake",
            name: "唤醒会话",
            trigger: "Control + Option + Space"
        ),
        stopShortcut: HotkeyDescriptor(
            id: "stop",
            name: "停止聆听并进入处理",
            trigger: "Control + Option + Return"
        ),
        cancelShortcut: HotkeyDescriptor(
            id: "cancel",
            name: "取消当前会话",
            trigger: "Control + Option + Escape"
        ),
        rewriteModifierHint: HotkeyDescriptor(
            id: "rewrite-lane",
            name: "选区改写通道",
            trigger: "选中内容后唤醒"
        )
    )
}

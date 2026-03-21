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
            name: "Wake session",
            trigger: "Control + Option + Space"
        ),
        stopShortcut: HotkeyDescriptor(
            id: "stop",
            name: "Stop listening and move to text stage",
            trigger: "Control + Option + Space (tap again)"
        ),
        cancelShortcut: HotkeyDescriptor(
            id: "cancel",
            name: "Cancel active session",
            trigger: "Control + Option + Escape"
        ),
        rewriteModifierHint: HotkeyDescriptor(
            id: "rewrite-lane",
            name: "Selection rewrite lane",
            trigger: "Hold Option when invoking with a selection"
        )
    )
}

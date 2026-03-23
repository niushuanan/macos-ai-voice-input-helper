import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let wakeSession = Self(
        "wakeSession",
        default: .init(.space, modifiers: [.control, .option])
    )

    static let cancelSession = Self(
        "cancelSession",
        default: .init(.escape)
    )

    static let brainstormSession = Self(
        "brainstormSession",
        default: .init(.b, modifiers: [.option, .command])
    )
}

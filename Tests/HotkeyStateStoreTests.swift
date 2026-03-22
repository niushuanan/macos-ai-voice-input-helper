import KeyboardShortcuts
import XCTest
@testable import PulseType

@MainActor
final class HotkeyStateStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeyboardShortcuts.reset(.wakeSession, .cancelSession)
    }

    override func tearDown() {
        KeyboardShortcuts.reset(.wakeSession, .cancelSession)
        super.tearDown()
    }

    func testRefreshReflectsLatestShortcutValues() {
        let store = HotkeyStateStore()

        KeyboardShortcuts.setShortcut(.init(.a, modifiers: [.command, .shift]), for: .wakeSession)
        KeyboardShortcuts.setShortcut(.init(.escape), for: .cancelSession)
        store.refresh()

        XCTAssertEqual(
            store.wakeShortcutText,
            KeyboardShortcuts.getShortcut(for: .wakeSession)?
                .description
                .replacingOccurrences(of: "-", with: " + ")
        )
        XCTAssertEqual(
            store.cancelShortcutText,
            KeyboardShortcuts.getShortcut(for: .cancelSession)?
                .description
                .replacingOccurrences(of: "-", with: " + ")
        )
    }

    func testConflictMessageAppearsWhenTwoHotkeysMatch() {
        let store = HotkeyStateStore()
        let shortcut = KeyboardShortcuts.Shortcut(.space, modifiers: [.command, .option])

        KeyboardShortcuts.setShortcut(shortcut, for: .wakeSession)
        KeyboardShortcuts.setShortcut(shortcut, for: .cancelSession)
        store.refresh()

        XCTAssertTrue(store.hasConflict)
        XCTAssertTrue(store.conflictMessage?.contains("重复") == true)
    }

    func testResetToDefaultsRestoresDefaultShortcuts() {
        let store = HotkeyStateStore()

        KeyboardShortcuts.setShortcut(.init(.b, modifiers: [.command]), for: .wakeSession)
        KeyboardShortcuts.setShortcut(.init(.c, modifiers: [.option]), for: .cancelSession)
        store.resetToDefaults()

        XCTAssertEqual(store.wakeShortcutText, KeyboardShortcuts.Name.wakeSession.defaultShortcut?.description.replacingOccurrences(of: "-", with: " + "))
        XCTAssertEqual(store.cancelShortcutText, KeyboardShortcuts.Name.cancelSession.defaultShortcut?.description.replacingOccurrences(of: "-", with: " + "))
        XCTAssertFalse(store.hasConflict)
    }
}

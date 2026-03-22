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
        UserDefaults.standard.removeObject(forKey: "hotkeys.wake.mode.v1")
        UserDefaults.standard.removeObject(forKey: "hotkeys.cancel.mode.v1")
        UserDefaults.standard.removeObject(forKey: "hotkeys.wake.modifier.v1")
        UserDefaults.standard.removeObject(forKey: "hotkeys.cancel.modifier.v1")
        super.tearDown()
    }

    func testRefreshReflectsLatestShortcutValues() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = HotkeyStateStore(defaults: defaults)

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
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = HotkeyStateStore(defaults: defaults)
        let shortcut = KeyboardShortcuts.Shortcut(.space, modifiers: [.command, .option])

        KeyboardShortcuts.setShortcut(shortcut, for: .wakeSession)
        KeyboardShortcuts.setShortcut(shortcut, for: .cancelSession)
        store.refresh()

        XCTAssertTrue(store.hasConflict)
        XCTAssertTrue(store.conflictMessage?.contains("重复") == true)
    }

    func testResetToDefaultsRestoresDefaultShortcuts() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = HotkeyStateStore(defaults: defaults)

        KeyboardShortcuts.setShortcut(.init(.b, modifiers: [.command]), for: .wakeSession)
        KeyboardShortcuts.setShortcut(.init(.c, modifiers: [.option]), for: .cancelSession)
        store.resetToDefaults()

        XCTAssertEqual(store.wakeShortcutText, KeyboardShortcuts.Name.wakeSession.defaultShortcut?.description.replacingOccurrences(of: "-", with: " + "))
        XCTAssertEqual(store.cancelShortcutText, KeyboardShortcuts.Name.cancelSession.defaultShortcut?.description.replacingOccurrences(of: "-", with: " + "))
        XCTAssertFalse(store.hasConflict)
    }

    func testModifierTapModeSupportsCommandAndPersists() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = HotkeyStateStore(defaults: defaults)

        store.setTriggerMode(.modifierTap, for: .wakeSession)
        store.setModifier(.command, for: .wakeSession)
        store.refresh()

        XCTAssertEqual(store.wakeTriggerMode, .modifierTap)
        XCTAssertEqual(store.wakeModifier, .command)
        XCTAssertEqual(store.wakeShortcutText, "单击 Command")
        XCTAssertTrue(store.registrationText(for: .wakeSession).contains("修饰键单击"))
    }

    func testModifierTapConflictAppearsWhenTwoKeysUseSameModifier() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = HotkeyStateStore(defaults: defaults)

        store.setTriggerMode(.modifierTap, for: .wakeSession)
        store.setTriggerMode(.modifierTap, for: .cancelSession)
        store.setModifier(.command, for: .wakeSession)
        store.setModifier(.command, for: .cancelSession)
        store.refresh()

        XCTAssertTrue(store.hasConflict)
        XCTAssertTrue(store.conflictMessage?.contains("同一个修饰键") == true)
    }

    private var defaultsSuiteName: String {
        "HotkeyStateStoreTests.\(name)"
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Unable to create isolated UserDefaults for hotkey tests.")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}

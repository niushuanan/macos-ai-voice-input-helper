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
        store.setTriggerMode(.shortcut, for: .wakeSession)

        KeyboardShortcuts.setShortcut(.init(.a, modifiers: [.command, .shift]), for: .wakeSession)
        KeyboardShortcuts.setShortcut(.init(.k, modifiers: [.command]), for: .cancelSession)
        store.refresh()

        XCTAssertEqual(
            store.wakeShortcutText,
            KeyboardShortcuts.getShortcut(for: .wakeSession)?
                .description
                .replacingOccurrences(of: "-", with: " + ")
        )
        XCTAssertEqual(
            store.cancelShortcutText,
            KeyboardShortcuts.Shortcut(.escape)
                .description
                .replacingOccurrences(of: "-", with: " + ")
        )
    }

    func testConflictMessageAppearsWhenTwoHotkeysMatch() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = HotkeyStateStore(defaults: defaults)
        store.setTriggerMode(.shortcut, for: .wakeSession)
        let shortcut = KeyboardShortcuts.Shortcut(.escape)

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

        XCTAssertEqual(store.wakeTriggerMode, .modifierTap)
        XCTAssertEqual(store.wakeModifier, .leftOption)
        XCTAssertEqual(store.wakeShortcutText, "单键触发 · 左 Option")
        XCTAssertEqual(store.cancelShortcutText, KeyboardShortcuts.Shortcut(.escape).description.replacingOccurrences(of: "-", with: " + "))
        XCTAssertFalse(store.hasConflict)
    }

    func testDefaultWakeHotkeyUsesOptionModifierTap() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = HotkeyStateStore(defaults: defaults)

        XCTAssertEqual(store.wakeTriggerMode, .modifierTap)
        XCTAssertEqual(store.wakeModifier, .leftOption)
        XCTAssertEqual(store.wakeShortcutText, "单键触发 · 左 Option")
    }

    func testModifierTapModeSupportsCommandAndPersists() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = HotkeyStateStore(defaults: defaults)

        store.setTriggerMode(.modifierTap, for: .wakeSession)
        store.setModifier(.leftCommand, for: .wakeSession)
        store.refresh()

        XCTAssertEqual(store.wakeTriggerMode, .modifierTap)
        XCTAssertEqual(store.wakeModifier, .leftCommand)
        XCTAssertEqual(store.wakeShortcutText, "单键触发 · 左 Command")
        XCTAssertTrue(store.registrationText(for: .wakeSession).contains("单键触发"))
    }

    func testCancelHotkeyIsAlwaysFixedToEscape() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = HotkeyStateStore(defaults: defaults)

        store.setTriggerMode(.modifierTap, for: .wakeSession)
        store.setModifier(.leftCommand, for: .wakeSession)
        store.setModifier(.leftCommand, for: .cancelSession)
        KeyboardShortcuts.setShortcut(.init(.x, modifiers: [.command]), for: .cancelSession)
        store.refresh()

        XCTAssertEqual(store.cancelTriggerMode, .shortcut)
        XCTAssertEqual(store.cancelShortcutText, KeyboardShortcuts.Shortcut(.escape).description.replacingOccurrences(of: "-", with: " + "))
        XCTAssertTrue(store.registrationText(for: .cancelSession).contains("Esc"))
    }

    func testLegacyModifierValueMigratesToLeftVariant() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set("option", forKey: "hotkeys.wake.modifier.v1")

        let store = HotkeyStateStore(defaults: defaults)

        XCTAssertEqual(store.wakeModifier, .leftOption)
        XCTAssertEqual(store.wakeShortcutText, "单键触发 · 左 Option")
    }

    func testModifierKeyCodeMappingSupportsLeftAndRight() {
        XCTAssertEqual(HotkeyModifier.from(keyCode: 55), .leftCommand)
        XCTAssertEqual(HotkeyModifier.from(keyCode: 54), .rightCommand)
        XCTAssertEqual(HotkeyModifier.from(keyCode: 58), .leftOption)
        XCTAssertEqual(HotkeyModifier.from(keyCode: 61), .rightOption)
        XCTAssertEqual(HotkeyModifier.from(keyCode: 56), .leftShift)
        XCTAssertEqual(HotkeyModifier.from(keyCode: 60), .rightShift)
        XCTAssertEqual(HotkeyModifier.from(keyCode: 59), .leftControl)
        XCTAssertEqual(HotkeyModifier.from(keyCode: 62), .rightControl)
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

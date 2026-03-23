import KeyboardShortcuts
import XCTest
@testable import PulseType

@MainActor
final class HotkeyStateStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeyboardShortcuts.reset(.wakeSession, .cancelSession, .brainstormSession)
    }

    override func tearDown() {
        KeyboardShortcuts.reset(.wakeSession, .cancelSession, .brainstormSession)
        UserDefaults.standard.removeObject(forKey: "hotkeys.wake.mode.v1")
        UserDefaults.standard.removeObject(forKey: "hotkeys.cancel.mode.v1")
        UserDefaults.standard.removeObject(forKey: "hotkeys.wake.modifier.v1")
        UserDefaults.standard.removeObject(forKey: "hotkeys.cancel.modifier.v1")
        UserDefaults.standard.removeObject(forKey: "hotkeys.brainstorm.triggerType.v1")
        UserDefaults.standard.removeObject(forKey: "hotkeys.brainstorm.modifier.v1")
        super.tearDown()
    }

    func testLegacyWakeShortcutModeAndBindingAreMigratedToModifierTap() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set(HotkeyTriggerMode.shortcut.rawValue, forKey: "hotkeys.wake.mode.v1")
        defaults.set(HotkeyModifier.leftOption.rawValue, forKey: "hotkeys.wake.modifier.v1")
        KeyboardShortcuts.setShortcut(.init(.a, modifiers: [.command, .shift]), for: .wakeSession)

        let store = HotkeyStateStore(defaults: defaults)

        XCTAssertEqual(store.wakeTriggerMode, .modifierTap)
        XCTAssertEqual(store.wakeShortcutText, "单键触发 · 左 Option")
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: .wakeSession))
        XCTAssertEqual(defaults.string(forKey: "hotkeys.wake.mode.v1"), HotkeyTriggerMode.modifierTap.rawValue)
    }

    func testLegacyWakeShortcutConflictIsIgnoredAfterMigration() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set(HotkeyTriggerMode.shortcut.rawValue, forKey: "hotkeys.wake.mode.v1")
        let shortcut = KeyboardShortcuts.Shortcut(.escape)

        KeyboardShortcuts.setShortcut(shortcut, for: .wakeSession)
        KeyboardShortcuts.setShortcut(shortcut, for: .cancelSession)

        let store = HotkeyStateStore(defaults: defaults)
        store.refresh()

        XCTAssertEqual(store.wakeTriggerMode, .modifierTap)
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: .wakeSession))
        XCTAssertFalse(store.hasConflict)
        XCTAssertNil(store.conflictMessage)
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
        XCTAssertEqual(store.brainstormTriggerType, .doubleTapModifier)
        XCTAssertEqual(store.brainstormModifier, .rightOption)
        XCTAssertEqual(store.brainstormShortcutText, "双击修饰键 · 右 Option")
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

    func testBrainstormDefaultsUseDoubleTapRightOption() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = HotkeyStateStore(defaults: defaults)

        XCTAssertEqual(store.brainstormTriggerType, .doubleTapModifier)
        XCTAssertEqual(store.brainstormModifier, .rightOption)
        XCTAssertEqual(store.brainstormShortcutText, "双击修饰键 · 右 Option")
        XCTAssertTrue(store.brainstormShortcutRegistered)
    }

    func testBrainstormDoubleTapConflictWithWakeModifierIsDetected() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = HotkeyStateStore(defaults: defaults)
        store.setModifier(.leftOption, for: .wakeSession)
        store.setBrainstormTriggerType(.doubleTapModifier)
        store.setBrainstormModifier(.leftOption)

        XCTAssertTrue(store.hasConflict)
        XCTAssertEqual(store.conflictMessage, "头脑风暴触发键和主键重复，请更换其中一个。")
    }

    func testBrainstormGlobalShortcutConflictWithEscapeIsDetected() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = HotkeyStateStore(defaults: defaults)
        store.setBrainstormTriggerType(.globalShortcut)
        KeyboardShortcuts.setShortcut(.init(.escape), for: .brainstormSession)
        store.refresh()

        XCTAssertTrue(store.hasConflict)
        XCTAssertEqual(store.conflictMessage, "头脑风暴快捷键和取消键（Esc）重复，请更换。")
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

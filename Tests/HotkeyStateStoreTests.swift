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
        UserDefaults.standard.removeObject(forKey: "hotkeys.brainstorm.sequence.firstKeyCode.v1")
        UserDefaults.standard.removeObject(forKey: "hotkeys.brainstorm.sequence.secondKeyCode.v1")
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
        XCTAssertNil(store.brainstormSequenceFirstKey)
        XCTAssertNil(store.brainstormSequenceSecondKey)
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

    func testBrainstormSingleTapConflictWithWakeModifierIsBlocked() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = HotkeyStateStore(defaults: defaults)
        XCTAssertTrue(store.setBrainstormTriggerType(.singleTapModifier))
        let originalModifier = store.brainstormModifier
        let updated = store.setBrainstormModifier(store.wakeModifier)

        XCTAssertFalse(updated)
        XCTAssertEqual(store.brainstormModifier, originalModifier)
        XCTAssertFalse(store.hasConflict)
        XCTAssertNil(store.conflictMessage)
    }

    func testWakeModifierChangeIsBlockedWhenConflictingWithSingleTapBrainstorm() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = HotkeyStateStore(defaults: defaults)
        XCTAssertTrue(store.setBrainstormTriggerType(.singleTapModifier))
        XCTAssertTrue(store.setBrainstormModifier(.rightOption))

        let updated = store.setModifier(.rightOption, for: .wakeSession)

        XCTAssertFalse(updated)
        XCTAssertEqual(store.wakeModifier, .leftOption)
    }

    func testBrainstormDoubleTapCanReuseWakeModifier() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = HotkeyStateStore(defaults: defaults)
        XCTAssertTrue(store.setBrainstormTriggerType(.doubleTapModifier))

        let updated = store.setBrainstormModifier(store.wakeModifier)

        XCTAssertTrue(updated)
        XCTAssertEqual(store.brainstormModifier, store.wakeModifier)
        XCTAssertFalse(store.hasConflict)
    }

    func testBrainstormComboShortcutEscapeIsBlocked() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = HotkeyStateStore(defaults: defaults)
        XCTAssertTrue(store.setBrainstormTriggerType(.comboShortcut))
        let previousShortcut = store.brainstormShortcut
        let updated = store.setBrainstormShortcut(.init(.escape))

        XCTAssertFalse(updated)
        XCTAssertEqual(store.brainstormShortcut, previousShortcut)
    }

    func testBrainstormSequenceEscapeIsBlocked() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = HotkeyStateStore(defaults: defaults)
        XCTAssertTrue(store.setBrainstormTriggerType(.sequenceTwoStep))

        let updated = store.setBrainstormSequence(firstKey: .escape, secondKey: .a)

        XCTAssertFalse(updated)
        XCTAssertNil(store.brainstormSequenceFirstKey)
        XCTAssertNil(store.brainstormSequenceSecondKey)
    }

    func testBrainstormSequencePersistsAndUpdatesDescription() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let store = HotkeyStateStore(defaults: defaults)
        XCTAssertTrue(store.setBrainstormSequence(firstKey: .a, secondKey: .b))
        XCTAssertTrue(store.setBrainstormTriggerType(.sequenceTwoStep))

        XCTAssertEqual(store.brainstormSequenceFirstKey, .a)
        XCTAssertEqual(store.brainstormSequenceSecondKey, .b)
        XCTAssertTrue(store.hasBrainstormSequenceBinding)
        XCTAssertEqual(defaults.integer(forKey: "hotkeys.brainstorm.sequence.firstKeyCode.v1"), KeyboardShortcuts.Key.a.rawValue)
        XCTAssertEqual(defaults.integer(forKey: "hotkeys.brainstorm.sequence.secondKeyCode.v1"), KeyboardShortcuts.Key.b.rawValue)
        XCTAssertTrue(store.brainstormShortcutText.contains("顺序连按"))
        XCTAssertTrue(store.brainstormShortcutText.contains("->"))
    }

    func testBrainstormTriggerTypePersistenceSupportsAllModes() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        for mode in BrainstormTriggerType.allCases {
            defaults.set(mode.rawValue, forKey: "hotkeys.brainstorm.triggerType.v1")
            let store = HotkeyStateStore(defaults: defaults)
            XCTAssertEqual(store.brainstormTriggerType, mode)
        }
    }

    func testBrainstormTriggerTypeLegacyGlobalShortcutMigratesToComboShortcut() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set("globalShortcut", forKey: "hotkeys.brainstorm.triggerType.v1")

        let store = HotkeyStateStore(defaults: defaults)

        XCTAssertEqual(store.brainstormTriggerType, .comboShortcut)
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

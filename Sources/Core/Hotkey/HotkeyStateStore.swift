import AppKit
import Combine
import Foundation
import KeyboardShortcuts

enum HotkeyTriggerMode: String, CaseIterable, Identifiable {
    case shortcut
    case modifierTap

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shortcut:
            return "组合键"
        case .modifierTap:
            return "单键触发"
        }
    }
}

enum BrainstormTriggerType: String, CaseIterable, Identifiable {
    case comboShortcut
    case sequenceTwoStep
    case singleTapModifier
    case doubleTapModifier

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .comboShortcut:
            return "组合键"
        case .sequenceTwoStep:
            return "顺序连按"
        case .singleTapModifier:
            return "单击修饰键"
        case .doubleTapModifier:
            return "双击修饰键"
        }
    }

    static func loadCompatible(rawValue: String?) -> BrainstormTriggerType {
        switch rawValue {
        case BrainstormTriggerType.comboShortcut.rawValue, "globalShortcut":
            return .comboShortcut
        case BrainstormTriggerType.sequenceTwoStep.rawValue:
            return .sequenceTwoStep
        case BrainstormTriggerType.singleTapModifier.rawValue:
            return .singleTapModifier
        case BrainstormTriggerType.doubleTapModifier.rawValue, "doubleTapModifier":
            return .doubleTapModifier
        default:
            return .doubleTapModifier
        }
    }
}

enum HotkeyModifier: String, CaseIterable, Identifiable {
    case leftCommand
    case rightCommand
    case leftOption
    case rightOption
    case leftControl
    case rightControl
    case leftShift
    case rightShift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftCommand:
            return "左 Command"
        case .rightCommand:
            return "右 Command"
        case .leftOption:
            return "左 Option"
        case .rightOption:
            return "右 Option"
        case .leftControl:
            return "左 Control"
        case .rightControl:
            return "右 Control"
        case .leftShift:
            return "左 Shift"
        case .rightShift:
            return "右 Shift"
        }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        switch self {
        case .leftCommand, .rightCommand:
            return .command
        case .leftOption, .rightOption:
            return .option
        case .leftControl, .rightControl:
            return .control
        case .leftShift, .rightShift:
            return .shift
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .leftCommand:
            return 55
        case .rightCommand:
            return 54
        case .leftShift:
            return 56
        case .rightShift:
            return 60
        case .leftOption:
            return 58
        case .rightOption:
            return 61
        case .leftControl:
            return 59
        case .rightControl:
            return 62
        }
    }

    static func from(keyCode: UInt16) -> HotkeyModifier? {
        switch keyCode {
        case 55:
            return .leftCommand
        case 54:
            return .rightCommand
        case 56:
            return .leftShift
        case 60:
            return .rightShift
        case 58:
            return .leftOption
        case 61:
            return .rightOption
        case 59:
            return .leftControl
        case 62:
            return .rightControl
        default:
            return nil
        }
    }

    static func migrate(fromLegacyRawValue rawValue: String) -> HotkeyModifier? {
        switch rawValue {
        case "command":
            return .leftCommand
        case "option":
            return .leftOption
        case "control":
            return .leftControl
        case "shift":
            return .leftShift
        default:
            return nil
        }
    }
}

@MainActor
final class HotkeyStateStore: ObservableObject {
    private static let shortcutDidChangeNotification = Notification.Name(
        "KeyboardShortcuts_shortcutByNameDidChange"
    )

    @Published private(set) var wakeShortcutText: String
    @Published private(set) var cancelShortcutText: String
    @Published private(set) var brainstormShortcutText: String
    @Published private(set) var hasConflict: Bool
    @Published private(set) var conflictMessage: String?
    @Published private(set) var wakeShortcutRegistered: Bool
    @Published private(set) var cancelShortcutRegistered: Bool
    @Published private(set) var brainstormShortcutRegistered: Bool
    @Published private(set) var lastUpdatedAt: Date
    @Published private(set) var latestChangeMessage: String?
    @Published private(set) var wakeTriggerMode: HotkeyTriggerMode
    @Published private(set) var cancelTriggerMode: HotkeyTriggerMode
    @Published private(set) var wakeModifier: HotkeyModifier
    @Published private(set) var cancelModifier: HotkeyModifier
    @Published private(set) var brainstormTriggerType: BrainstormTriggerType
    @Published private(set) var brainstormModifier: HotkeyModifier
    @Published private(set) var brainstormSequenceFirstKey: KeyboardShortcuts.Key?
    @Published private(set) var brainstormSequenceSecondKey: KeyboardShortcuts.Key?

    private let notificationCenter: NotificationCenter
    private let defaults: UserDefaults
    private let now: () -> Date
    private var cancellables = Set<AnyCancellable>()
    private var hasCompletedInitialRefresh = false
    private var isApplyingFixedCancelShortcut = false

    private let wakeModeStorageKey = "hotkeys.wake.mode.v1"
    private let cancelModeStorageKey = "hotkeys.cancel.mode.v1"
    private let wakeModifierStorageKey = "hotkeys.wake.modifier.v1"
    private let cancelModifierStorageKey = "hotkeys.cancel.modifier.v1"
    private let brainstormTriggerTypeStorageKey = "hotkeys.brainstorm.triggerType.v1"
    private let brainstormModifierStorageKey = "hotkeys.brainstorm.modifier.v1"
    private let brainstormSequenceFirstKeyCodeStorageKey = "hotkeys.brainstorm.sequence.firstKeyCode.v1"
    private let brainstormSequenceSecondKeyCodeStorageKey = "hotkeys.brainstorm.sequence.secondKeyCode.v1"
    private let fixedCancelShortcut = KeyboardShortcuts.Shortcut(.escape)

    init(
        notificationCenter: NotificationCenter = .default,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.notificationCenter = notificationCenter
        self.defaults = defaults
        self.now = now

        self.wakeTriggerMode = .modifierTap
        self.cancelTriggerMode = .shortcut
        self.wakeModifier = Self.loadModifier(
            defaults: defaults,
            key: wakeModifierStorageKey,
            fallback: .leftOption
        )
        self.cancelModifier = .leftOption
        self.brainstormTriggerType = BrainstormTriggerType.loadCompatible(
            rawValue: defaults.string(forKey: brainstormTriggerTypeStorageKey)
        )
        self.brainstormModifier = Self.loadModifier(
            defaults: defaults,
            key: brainstormModifierStorageKey,
            fallback: .rightOption
        )
        self.brainstormSequenceFirstKey = Self.loadKey(
            defaults: defaults,
            key: brainstormSequenceFirstKeyCodeStorageKey
        )
        self.brainstormSequenceSecondKey = Self.loadKey(
            defaults: defaults,
            key: brainstormSequenceSecondKeyCodeStorageKey
        )

        self.wakeShortcutText = "未设置"
        self.cancelShortcutText = "未设置"
        self.brainstormShortcutText = "未设置"
        self.hasConflict = false
        self.conflictMessage = nil
        self.wakeShortcutRegistered = false
        self.cancelShortcutRegistered = false
        self.brainstormShortcutRegistered = false
        self.lastUpdatedAt = now()
        enforceWakeModifierTapMode()
        enforceFixedCancelShortcut()

        refresh()

        notificationCenter.publisher(for: Self.shortcutDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else {
                    return
                }
                if
                    let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
                    name != .wakeSession,
                    name != .cancelSession,
                    name != .brainstormSession
                {
                    return
                }
                if self.isApplyingFixedCancelShortcut {
                    return
                }
                self.refresh()
            }
            .store(in: &cancellables)
    }

    @discardableResult
    func setTriggerMode(_ mode: HotkeyTriggerMode, for name: KeyboardShortcuts.Name) -> Bool {
        switch name {
        case .wakeSession:
            _ = mode
            enforceWakeModifierTapMode()
        case .cancelSession:
            _ = mode
            enforceFixedCancelShortcut()
        case .brainstormSession:
            let mapped: BrainstormTriggerType = (mode == .modifierTap)
                ? .singleTapModifier
                : .comboShortcut
            return setBrainstormTriggerType(mapped)
        default:
            return false
        }
        refresh()
        return true
    }

    @discardableResult
    func setModifier(_ modifier: HotkeyModifier, for name: KeyboardShortcuts.Name) -> Bool {
        switch name {
        case .wakeSession:
            if brainstormTriggerType == .singleTapModifier, brainstormModifier == modifier {
                refresh()
                return false
            }
            wakeModifier = modifier
            defaults.set(modifier.rawValue, forKey: wakeModifierStorageKey)
        case .cancelSession:
            _ = modifier
            enforceFixedCancelShortcut()
        case .brainstormSession:
            return setBrainstormModifier(modifier)
        default:
            return false
        }
        refresh()
        return true
    }

    @discardableResult
    func setBrainstormTriggerType(_ triggerType: BrainstormTriggerType) -> Bool {
        if triggerType == .singleTapModifier, wakeModifier == brainstormModifier {
            refresh()
            return false
        }
        brainstormTriggerType = triggerType
        defaults.set(triggerType.rawValue, forKey: brainstormTriggerTypeStorageKey)
        refresh()
        return true
    }

    @discardableResult
    func setBrainstormModifier(_ modifier: HotkeyModifier) -> Bool {
        if brainstormTriggerType == .singleTapModifier, modifier == wakeModifier {
            refresh()
            return false
        }
        brainstormModifier = modifier
        defaults.set(modifier.rawValue, forKey: brainstormModifierStorageKey)
        refresh()
        return true
    }

    @discardableResult
    func setBrainstormShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) -> Bool {
        if shortcut?.key == .escape {
            refresh()
            return false
        }
        KeyboardShortcuts.setShortcut(shortcut, for: .brainstormSession)
        refresh()
        return true
    }

    @discardableResult
    func setBrainstormSequence(
        firstKey: KeyboardShortcuts.Key,
        secondKey: KeyboardShortcuts.Key
    ) -> Bool {
        if firstKey == .escape || secondKey == .escape {
            refresh()
            return false
        }
        brainstormSequenceFirstKey = firstKey
        brainstormSequenceSecondKey = secondKey
        defaults.set(firstKey.rawValue, forKey: brainstormSequenceFirstKeyCodeStorageKey)
        defaults.set(secondKey.rawValue, forKey: brainstormSequenceSecondKeyCodeStorageKey)
        refresh()
        return true
    }

    var hasBrainstormSequenceBinding: Bool {
        brainstormSequenceFirstKey != nil && brainstormSequenceSecondKey != nil
    }

    var brainstormShortcut: KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: .brainstormSession)
    }

    func refresh() {
        enforceWakeModifierTapMode()
        enforceFixedCancelShortcut()
        let previousWakeShortcutText = wakeShortcutText
        let previousCancelShortcutText = cancelShortcutText
        let previousBrainstormShortcutText = brainstormShortcutText

        wakeShortcutText = describeBinding(
            mode: wakeTriggerMode,
            modifier: wakeModifier,
            shortcut: nil
        )
        cancelShortcutText = describeBinding(
            mode: cancelTriggerMode,
            modifier: cancelModifier,
            shortcut: fixedCancelShortcut
        )
        brainstormShortcutText = describeBrainstormBinding(
            triggerType: brainstormTriggerType,
            modifier: brainstormModifier,
            shortcut: brainstormShortcut
        )
        wakeShortcutRegistered = registrationState(for: .wakeSession, mode: wakeTriggerMode)
        cancelShortcutRegistered = registrationState(for: .cancelSession, mode: cancelTriggerMode)
        switch brainstormTriggerType {
        case .singleTapModifier, .doubleTapModifier:
            brainstormShortcutRegistered = true
        case .sequenceTwoStep:
            brainstormShortcutRegistered = hasBrainstormSequenceBinding
        case .comboShortcut:
            brainstormShortcutRegistered = registrationState(for: .brainstormSession, mode: .shortcut)
        }
        lastUpdatedAt = now()

        if let conflict = resolveConflictMessage() {
            hasConflict = true
            conflictMessage = conflict
        } else {
            hasConflict = false
            conflictMessage = nil
        }

        if hasCompletedInitialRefresh {
            var changes: [String] = []
            if previousWakeShortcutText != wakeShortcutText {
                changes.append("主键已更新")
            }
            if previousCancelShortcutText != cancelShortcutText {
                changes.append("取消键已锁定为 Esc")
            }
            if previousBrainstormShortcutText != brainstormShortcutText {
                changes.append("头脑风暴触发已更新")
            }
            if !changes.isEmpty {
                latestChangeMessage = changes.joined(separator: "，") + "，现在已经生效。"
            }
        } else {
            hasCompletedInitialRefresh = true
        }
    }

    func resetToDefaults() {
        KeyboardShortcuts.setShortcut(nil, for: .wakeSession)
        KeyboardShortcuts.setShortcut(fixedCancelShortcut, for: .cancelSession)
        KeyboardShortcuts.setShortcut(.init(.b, modifiers: [.option, .command]), for: .brainstormSession)
        wakeTriggerMode = .modifierTap
        cancelTriggerMode = .shortcut
        wakeModifier = .leftOption
        cancelModifier = .leftOption
        brainstormTriggerType = .doubleTapModifier
        brainstormModifier = .rightOption
        defaults.set(wakeTriggerMode.rawValue, forKey: wakeModeStorageKey)
        defaults.set(wakeModifier.rawValue, forKey: wakeModifierStorageKey)
        defaults.removeObject(forKey: cancelModeStorageKey)
        defaults.removeObject(forKey: cancelModifierStorageKey)
        defaults.set(brainstormTriggerType.rawValue, forKey: brainstormTriggerTypeStorageKey)
        defaults.set(brainstormModifier.rawValue, forKey: brainstormModifierStorageKey)
        defaults.removeObject(forKey: brainstormSequenceFirstKeyCodeStorageKey)
        defaults.removeObject(forKey: brainstormSequenceSecondKeyCodeStorageKey)
        brainstormSequenceFirstKey = nil
        brainstormSequenceSecondKey = nil
        refresh()
    }

    func registrationText(for name: KeyboardShortcuts.Name) -> String {
        switch name {
        case .wakeSession:
            return wakeShortcutRegistered ? "主键监听已生效（单键触发）" : "主键还没有生效"
        case .cancelSession:
            return cancelShortcutRegistered ? "取消键监听已生效（Esc）" : "取消键还没有生效（Esc）"
        case .brainstormSession:
            switch brainstormTriggerType {
            case .singleTapModifier:
                return "头脑风暴监听已生效（单击\(brainstormModifier.displayName)）"
            case .doubleTapModifier:
                return "头脑风暴监听已生效（双击\(brainstormModifier.displayName)）"
            case .comboShortcut:
                if brainstormShortcut != nil {
                    return brainstormShortcutRegistered ? "头脑风暴监听已生效（组合键）" : "头脑风暴组合键已设置但尚未生效"
                }
                return "头脑风暴组合键还没有设置"
            case .sequenceTwoStep:
                return brainstormShortcutRegistered ? "头脑风暴监听已生效（顺序连按）" : "头脑风暴顺序连按还没有设置"
            }
        default:
            return "监听状态未知"
        }
    }

    func clearLatestChangeMessage() {
        latestChangeMessage = nil
    }

    private func resolveConflictMessage() -> String? {
        if wakeTriggerMode == .modifierTap, cancelTriggerMode == .modifierTap, wakeModifier == cancelModifier {
            return "主键与取消键使用了同一个修饰键，会导致会话行为不明确。"
        }

        if brainstormTriggerType == .singleTapModifier, wakeModifier == brainstormModifier {
            return "头脑风暴触发键和主键重复，请更换其中一个。"
        }

        if brainstormTriggerType == .comboShortcut, brainstormShortcut?.key == .escape {
            return "头脑风暴组合键不能使用 Esc，请更换。"
        }

        if brainstormTriggerType == .sequenceTwoStep {
            if brainstormSequenceFirstKey == .escape || brainstormSequenceSecondKey == .escape {
                return "头脑风暴顺序连按不能使用 Esc，请更换。"
            }
        }

        return nil
    }

    private func registrationState(for name: KeyboardShortcuts.Name, mode: HotkeyTriggerMode) -> Bool {
        switch mode {
        case .shortcut:
            if name == .brainstormSession {
                return brainstormShortcut != nil && KeyboardShortcuts.isEnabled(for: name)
            }
            return KeyboardShortcuts.isEnabled(for: name)
        case .modifierTap:
            return true
        }
    }

    private func describeBinding(
        mode: HotkeyTriggerMode,
        modifier: HotkeyModifier,
        shortcut: KeyboardShortcuts.Shortcut?
    ) -> String {
        switch mode {
        case .shortcut:
            return describeShortcut(shortcut)
        case .modifierTap:
            return "单键触发 · \(modifier.displayName)"
        }
    }

    private func describeBrainstormBinding(
        triggerType: BrainstormTriggerType,
        modifier: HotkeyModifier,
        shortcut: KeyboardShortcuts.Shortcut?
    ) -> String {
        switch triggerType {
        case .comboShortcut:
            return "组合键 · \(describeShortcut(shortcut))"
        case .sequenceTwoStep:
            return "顺序连按 · \(describeSequenceBinding())"
        case .singleTapModifier:
            return "单击修饰键 · \(modifier.displayName)"
        case .doubleTapModifier:
            return "双击修饰键 · \(modifier.displayName)"
        }
    }

    private func describeSequenceBinding() -> String {
        guard
            let first = brainstormSequenceFirstKey,
            let second = brainstormSequenceSecondKey
        else {
            return "未设置"
        }
        return "\(describeKey(first)) -> \(describeKey(second))"
    }

    private func describeShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) -> String {
        shortcut?
            .description
            .replacingOccurrences(of: "-", with: " + ")
            ?? "未设置"
    }

    private func describeKey(_ key: KeyboardShortcuts.Key) -> String {
        KeyboardShortcuts.Shortcut(key)
            .description
            .replacingOccurrences(of: "-", with: " + ")
    }

    private func enforceFixedCancelShortcut() {
        cancelTriggerMode = .shortcut
        cancelModifier = .leftOption
        defaults.removeObject(forKey: cancelModeStorageKey)
        defaults.removeObject(forKey: cancelModifierStorageKey)
        if KeyboardShortcuts.getShortcut(for: .cancelSession) != fixedCancelShortcut {
            isApplyingFixedCancelShortcut = true
            KeyboardShortcuts.setShortcut(fixedCancelShortcut, for: .cancelSession)
            isApplyingFixedCancelShortcut = false
        }
    }

    private func enforceWakeModifierTapMode() {
        wakeTriggerMode = .modifierTap
        defaults.set(HotkeyTriggerMode.modifierTap.rawValue, forKey: wakeModeStorageKey)
        if KeyboardShortcuts.getShortcut(for: .wakeSession) != nil {
            KeyboardShortcuts.setShortcut(nil, for: .wakeSession)
        }
    }

    private static func loadModifier(
        defaults: UserDefaults,
        key: String,
        fallback: HotkeyModifier
    ) -> HotkeyModifier {
        guard
            let raw = defaults.string(forKey: key),
            let modifier = HotkeyModifier(rawValue: raw) ?? HotkeyModifier.migrate(fromLegacyRawValue: raw)
        else {
            return fallback
        }
        return modifier
    }

    private static func loadKey(
        defaults: UserDefaults,
        key: String
    ) -> KeyboardShortcuts.Key? {
        guard defaults.object(forKey: key) != nil else {
            return nil
        }
        return KeyboardShortcuts.Key(rawValue: defaults.integer(forKey: key))
    }
}

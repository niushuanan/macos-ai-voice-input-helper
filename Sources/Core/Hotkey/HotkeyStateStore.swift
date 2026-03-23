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
            return "修饰键单击"
        }
    }
}

enum HotkeyModifier: String, CaseIterable, Identifiable {
    case command
    case option
    case control
    case shift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .command:
            return "Command"
        case .option:
            return "Option"
        case .control:
            return "Control"
        case .shift:
            return "Shift"
        }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        switch self {
        case .command:
            return .command
        case .option:
            return .option
        case .control:
            return .control
        case .shift:
            return .shift
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
    @Published private(set) var hasConflict: Bool
    @Published private(set) var conflictMessage: String?
    @Published private(set) var wakeShortcutRegistered: Bool
    @Published private(set) var cancelShortcutRegistered: Bool
    @Published private(set) var lastUpdatedAt: Date
    @Published private(set) var latestChangeMessage: String?
    @Published private(set) var wakeTriggerMode: HotkeyTriggerMode
    @Published private(set) var cancelTriggerMode: HotkeyTriggerMode
    @Published private(set) var wakeModifier: HotkeyModifier
    @Published private(set) var cancelModifier: HotkeyModifier

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
    private let fixedCancelShortcut = KeyboardShortcuts.Shortcut(.escape)

    init(
        notificationCenter: NotificationCenter = .default,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.notificationCenter = notificationCenter
        self.defaults = defaults
        self.now = now

        self.wakeTriggerMode = Self.loadTriggerMode(
            defaults: defaults,
            key: wakeModeStorageKey,
            fallback: .modifierTap
        )
        self.cancelTriggerMode = .shortcut
        self.wakeModifier = Self.loadModifier(
            defaults: defaults,
            key: wakeModifierStorageKey,
            fallback: .option
        )
        self.cancelModifier = .option

        self.wakeShortcutText = "未设置"
        self.cancelShortcutText = "未设置"
        self.hasConflict = false
        self.conflictMessage = nil
        self.wakeShortcutRegistered = false
        self.cancelShortcutRegistered = false
        self.lastUpdatedAt = now()
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
                    name != .cancelSession
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

    func setTriggerMode(_ mode: HotkeyTriggerMode, for name: KeyboardShortcuts.Name) {
        switch name {
        case .wakeSession:
            wakeTriggerMode = mode
            defaults.set(mode.rawValue, forKey: wakeModeStorageKey)
        case .cancelSession:
            _ = mode
            enforceFixedCancelShortcut()
        default:
            return
        }
        refresh()
    }

    func setModifier(_ modifier: HotkeyModifier, for name: KeyboardShortcuts.Name) {
        switch name {
        case .wakeSession:
            wakeModifier = modifier
            defaults.set(modifier.rawValue, forKey: wakeModifierStorageKey)
        case .cancelSession:
            _ = modifier
            enforceFixedCancelShortcut()
        default:
            return
        }
        refresh()
    }

    func refresh() {
        enforceFixedCancelShortcut()
        let previousWakeShortcutText = wakeShortcutText
        let previousCancelShortcutText = cancelShortcutText

        let wakeShortcut = KeyboardShortcuts.getShortcut(for: .wakeSession)
        let cancelShortcut = fixedCancelShortcut

        wakeShortcutText = describeBinding(
            mode: wakeTriggerMode,
            modifier: wakeModifier,
            shortcut: wakeShortcut
        )
        cancelShortcutText = describeBinding(
            mode: cancelTriggerMode,
            modifier: cancelModifier,
            shortcut: cancelShortcut
        )
        wakeShortcutRegistered = registrationState(for: .wakeSession, mode: wakeTriggerMode)
        cancelShortcutRegistered = registrationState(for: .cancelSession, mode: cancelTriggerMode)
        lastUpdatedAt = now()

        if let conflict = resolveConflictMessage(
            wakeShortcut: wakeShortcut,
            cancelShortcut: cancelShortcut
        ) {
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
            if !changes.isEmpty {
                latestChangeMessage = changes.joined(separator: "，") + "，现在已经生效。"
            }
        } else {
            hasCompletedInitialRefresh = true
        }
    }

    func resetToDefaults() {
        KeyboardShortcuts.reset(.wakeSession)
        KeyboardShortcuts.setShortcut(fixedCancelShortcut, for: .cancelSession)
        wakeTriggerMode = .modifierTap
        cancelTriggerMode = .shortcut
        wakeModifier = .option
        cancelModifier = .option
        defaults.set(wakeTriggerMode.rawValue, forKey: wakeModeStorageKey)
        defaults.set(wakeModifier.rawValue, forKey: wakeModifierStorageKey)
        defaults.removeObject(forKey: cancelModeStorageKey)
        defaults.removeObject(forKey: cancelModifierStorageKey)
        refresh()
    }

    func registrationText(for name: KeyboardShortcuts.Name) -> String {
        switch name {
        case .wakeSession:
            switch wakeTriggerMode {
            case .shortcut:
                return wakeShortcutRegistered ? "主键监听已生效（组合键）" : "主键还没有生效"
            case .modifierTap:
                return wakeShortcutRegistered ? "主键监听已生效（修饰键单击）" : "主键还没有生效"
            }
        case .cancelSession:
            return cancelShortcutRegistered ? "取消键监听已生效（Esc）" : "取消键还没有生效（Esc）"
        default:
            return "监听状态未知"
        }
    }

    func clearLatestChangeMessage() {
        latestChangeMessage = nil
    }

    private func resolveConflictMessage(
        wakeShortcut: KeyboardShortcuts.Shortcut?,
        cancelShortcut: KeyboardShortcuts.Shortcut?
    ) -> String? {
        if wakeTriggerMode == .modifierTap, cancelTriggerMode == .modifierTap, wakeModifier == cancelModifier {
            return "主键与取消键使用了同一个修饰键，会导致会话行为不明确。"
        }

        if
            wakeTriggerMode == .shortcut,
            let wakeShortcut,
            wakeShortcut == fixedCancelShortcut
        {
            return "主键与取消键重复，会导致会话行为不明确。"
        }

        return nil
    }

    private func registrationState(for name: KeyboardShortcuts.Name, mode: HotkeyTriggerMode) -> Bool {
        switch mode {
        case .shortcut:
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
            return "单击 \(modifier.displayName)"
        }
    }

    private func describeShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) -> String {
        shortcut?
            .description
            .replacingOccurrences(of: "-", with: " + ")
            ?? "未设置"
    }

    private func enforceFixedCancelShortcut() {
        cancelTriggerMode = .shortcut
        cancelModifier = .option
        defaults.removeObject(forKey: cancelModeStorageKey)
        defaults.removeObject(forKey: cancelModifierStorageKey)
        if KeyboardShortcuts.getShortcut(for: .cancelSession) != fixedCancelShortcut {
            isApplyingFixedCancelShortcut = true
            KeyboardShortcuts.setShortcut(fixedCancelShortcut, for: .cancelSession)
            isApplyingFixedCancelShortcut = false
        }
    }

    private static func loadTriggerMode(
        defaults: UserDefaults,
        key: String,
        fallback: HotkeyTriggerMode
    ) -> HotkeyTriggerMode {
        guard
            let raw = defaults.string(forKey: key),
            let mode = HotkeyTriggerMode(rawValue: raw)
        else {
            return fallback
        }
        return mode
    }

    private static func loadModifier(
        defaults: UserDefaults,
        key: String,
        fallback: HotkeyModifier
    ) -> HotkeyModifier {
        guard
            let raw = defaults.string(forKey: key),
            let modifier = HotkeyModifier(rawValue: raw)
        else {
            return fallback
        }
        return modifier
    }
}

import Combine
import Foundation
import KeyboardShortcuts

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

    private let notificationCenter: NotificationCenter
    private let now: () -> Date
    private var cancellables = Set<AnyCancellable>()

    init(
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.notificationCenter = notificationCenter
        self.now = now
        self.wakeShortcutText = Self.describeShortcut(KeyboardShortcuts.getShortcut(for: .wakeSession))
        self.cancelShortcutText = Self.describeShortcut(KeyboardShortcuts.getShortcut(for: .cancelSession))
        self.hasConflict = false
        self.conflictMessage = nil
        self.wakeShortcutRegistered = KeyboardShortcuts.isEnabled(for: .wakeSession)
        self.cancelShortcutRegistered = KeyboardShortcuts.isEnabled(for: .cancelSession)
        self.lastUpdatedAt = now()

        refresh()

        notificationCenter.publisher(for: Self.shortcutDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                if
                    let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
                    name != .wakeSession,
                    name != .cancelSession
                {
                    return
                }
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    func refresh() {
        let wakeShortcut = KeyboardShortcuts.getShortcut(for: .wakeSession)
        let cancelShortcut = KeyboardShortcuts.getShortcut(for: .cancelSession)

        wakeShortcutText = Self.describeShortcut(wakeShortcut)
        cancelShortcutText = Self.describeShortcut(cancelShortcut)
        wakeShortcutRegistered = KeyboardShortcuts.isEnabled(for: .wakeSession)
        cancelShortcutRegistered = KeyboardShortcuts.isEnabled(for: .cancelSession)
        lastUpdatedAt = now()

        if let wakeShortcut, let cancelShortcut, wakeShortcut == cancelShortcut {
            hasConflict = true
            conflictMessage = "主键与取消键重复，会导致会话行为不明确。"
        } else {
            hasConflict = false
            conflictMessage = nil
        }
    }

    func resetToDefaults() {
        KeyboardShortcuts.reset(.wakeSession, .cancelSession)
        refresh()
    }

    func registrationText(for name: KeyboardShortcuts.Name) -> String {
        switch name {
        case .wakeSession:
            return wakeShortcutRegistered ? "主键监听已生效" : "主键还没有生效"
        case .cancelSession:
            return cancelShortcutRegistered ? "取消键监听已生效" : "取消键还没有生效"
        default:
            return "监听状态未知"
        }
    }

    private static func describeShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) -> String {
        shortcut?
            .description
            .replacingOccurrences(of: "-", with: " + ")
            ?? "未设置"
    }
}

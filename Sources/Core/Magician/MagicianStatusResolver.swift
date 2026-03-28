import EventKit
import Foundation

enum MagicianFeatureRequirement: Equatable {
    case ready
    case blocked(reason: String, prompt: MagicianPermissionPromptModel)
}

struct MagicianFeatureStatusResolution: Equatable {
    let status: MagicianFeatureStatus
    let reason: String?
    let prompt: MagicianPermissionPromptModel?
}

struct MagicianStatusResolver {
    func resolve(
        feature: MagicianFeatureID,
        isEnabled: Bool,
        dependencies: MagicianDependencySnapshot
    ) -> MagicianFeatureStatusResolution {
        let requirement = requirement(for: feature, dependencies: dependencies)
        switch requirement {
        case .ready:
            return MagicianFeatureStatusResolution(
                status: isEnabled ? .enabled : .notEnabled,
                reason: nil,
                prompt: nil
            )
        case let .blocked(reason, prompt):
            return MagicianFeatureStatusResolution(
                status: .needsPermission,
                reason: reason,
                prompt: prompt
            )
        }
    }

    func requirement(
        for feature: MagicianFeatureID,
        dependencies: MagicianDependencySnapshot
    ) -> MagicianFeatureRequirement {
        switch feature {
        case .textTransform:
            switch dependencies.accessibilityState {
            case .granted, .notRequired:
                return .ready
            case .notRequested, .pending:
                return .blocked(
                    reason: "需要先开启辅助功能权限。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "需要辅助功能权限",
                        message: "文字处理要读取并替换选中文本，请先允许辅助功能权限。",
                        primaryButtonTitle: "请求权限",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .requestAccessibility
                    )
                )
            case .denied:
                return .blocked(
                    reason: "辅助功能权限已被拒绝，请到系统设置手动开启。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "需要辅助功能权限",
                        message: "文字处理要读取并替换选中文本，请到系统设置开启辅助功能权限。",
                        primaryButtonTitle: "打开系统设置",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .openSystemSettings(
                            urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                        )
                    )
                )
            }

        case .createEvent:
            let eventStatus = dependencies.eventAuthorizationStatus
            if hasEventAccess(eventStatus) {
                return .ready
            }

            if eventStatus == .notDetermined {
                return .blocked(
                    reason: "需要先允许日历权限。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "需要日历权限",
                        message: "一键建日程要写入系统日历，请先允许日历访问。",
                        primaryButtonTitle: "请求权限",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .requestCalendarAccess
                    )
                )
            }

            return .blocked(
                reason: "日历权限不可用，请到系统设置开启。",
                prompt: MagicianPermissionPromptModel(
                    feature: feature,
                    title: "需要日历权限",
                    message: "一键建日程要写入系统日历，请到系统设置开启日历权限。",
                    primaryButtonTitle: "打开系统设置",
                    secondaryButtonTitle: "稍后再说",
                    primaryAction: .openSystemSettings(
                        urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                    )
                )
            )

        case .createNote:
            if dependencies.notesAppAvailable {
                return .ready
            }
            if dependencies.shortcutsCLIAvailable, dependencies.createNoteShortcutExists {
                return .ready
            }
            return .blocked(
                reason: "备忘录服务不可用，请先打开 Notes 或配置 Shortcut“\(dependencies.createNoteShortcutName)”。",
                prompt: MagicianPermissionPromptModel(
                    feature: feature,
                    title: "备忘录服务不可用",
                    message: "写入备忘录优先用 Notes 直写，若不可用会回退到 Shortcut“\(dependencies.createNoteShortcutName)”。请先打开 Notes，或在 Shortcuts 配置同名指令。",
                    primaryButtonTitle: "打开 Notes",
                    secondaryButtonTitle: "稍后再说",
                    primaryAction: .openNotesApp
                )
            )

        case .composeEmailDraft:
            guard
                dependencies.composeEmailAvailable
                    || dependencies.mailtoAvailable
                    || dependencies.mailAppAvailable
            else {
                return .blocked(
                    reason: "当前无法使用邮件助手，请先打开 Mail 并完成账号配置。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "邮件服务不可用",
                        message: "邮件助手依赖系统 Mail 服务。请先打开 Mail，并确认系统里已经配置好可用账号。",
                        primaryButtonTitle: "打开 Mail",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .openMailApp
                    )
                )
            }
            return .ready

        case .feishuCLI:
            guard dependencies.feishuCLIAvailable else {
                return .blocked(
                    reason: "未检测到飞书 CLI，请先安装并完成登录。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "飞书 CLI 不可用",
                        message: "系统里未检测到 feishu 或 lark-cli 可执行文件。请先安装 CLI，再回到这里开启。",
                        primaryButtonTitle: "打开开源地址",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .openExternalURL(
                            urlString: "https://github.com/larksuite/cli"
                        )
                    )
                )
            }
            return .ready
        }
    }

    private func hasEventAccess(_ status: EKAuthorizationStatus) -> Bool {
        status == .fullAccess || status == .writeOnly
    }
}

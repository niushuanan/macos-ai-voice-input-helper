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

        case .webSearch:
            return .ready

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
            guard dependencies.shortcutsCLIAvailable else {
                return .blocked(
                    reason: "当前系统未检测到 Shortcuts CLI（shortcuts）。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "Shortcuts 不可用",
                        message: "写入备忘录依赖系统 Shortcuts，请先确认系统可用并打开后再试。",
                        primaryButtonTitle: "打开 Shortcuts",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .openShortcutsApp
                    )
                )
            }
            return .ready

        case .composeEmailDraft:
            guard dependencies.composeEmailAvailable else {
                return .blocked(
                    reason: "当前无法创建邮件草稿，请先配置 Mail 账号。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "邮件服务不可用",
                        message: "邮件草稿依赖系统 Mail 服务，请先打开 Mail 并完成账号配置。",
                        primaryButtonTitle: "打开 Mail",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .openMailApp
                    )
                )
            }
            return .ready
        }
    }

    private func hasEventAccess(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess || status == .writeOnly
        }
        return status == .authorized
    }
}

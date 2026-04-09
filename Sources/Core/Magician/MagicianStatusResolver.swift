import EventKit
import Foundation

enum MagicianFeatureRequirement: Equatable {
    case ready
    case blocked(
        gateKind: MagicianFeatureGateKind,
        reason: String,
        prompt: MagicianPermissionPromptModel
    )
}

struct MagicianFeatureStatusResolution: Equatable {
    let status: MagicianFeatureStatus
    let availability: MagicianFeatureAvailability
    let gateKind: MagicianFeatureGateKind
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
                availability: .ready,
                gateKind: .ready,
                reason: nil,
                prompt: nil
            )
        case let .blocked(gateKind, reason, prompt):
            return MagicianFeatureStatusResolution(
                status: isEnabled ? .enabled : .notEnabled,
                availability: .blocked,
                gateKind: gateKind,
                reason: reason,
                prompt: prompt
            )
        }
    }

    func requirement(
        for feature: MagicianFeatureID,
        dependencies: MagicianDependencySnapshot
    ) -> MagicianFeatureRequirement {
        switch feature.canonicalFeature {
        case .textTransform:
            switch dependencies.accessibilityState {
            case .granted, .notRequired:
                guard dependencies.textModelReady else {
                    return .blocked(
                        gateKind: .modelDependency,
                        reason: "文本模型还没准备好，请先到模型页完成文本处理配置。",
                        prompt: MagicianPermissionPromptModel(
                            feature: feature,
                            title: "需要可用的文本模型",
                            message: "文本处理除了辅助功能，还需要一套可用的文本模型配置。",
                            primaryButtonTitle: "去模型页检查",
                            secondaryButtonTitle: "稍后再说",
                            primaryAction: .openSettingsSection(sectionID: "model")
                        )
                    )
                }
                return .ready

            case .notRequested, .pending:
                return .blocked(
                    gateKind: .systemPermission,
                    reason: "需要先开启辅助功能权限。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "需要辅助功能权限",
                        message: "文本处理要读取并替换选中文本，请先允许辅助功能权限。",
                        primaryButtonTitle: "请求权限",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .requestAccessibility
                    )
                )

            case .denied:
                return .blocked(
                    gateKind: .systemPermission,
                    reason: "辅助功能权限已被拒绝，请到系统设置手动开启。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "需要辅助功能权限",
                        message: "文本处理要读取并替换选中文本，请到系统设置开启辅助功能权限。",
                        primaryButtonTitle: "打开系统设置",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .openSystemSettings(
                            urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                        )
                    )
                )
            }

        case .calendar:
            let eventStatus = dependencies.eventAuthorizationStatus
            if hasEventAccess(eventStatus) {
                return .ready
            }

            if eventStatus == .notDetermined {
                return .blocked(
                    gateKind: .systemPermission,
                    reason: "需要先允许日历权限。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "需要日历权限",
                        message: "日历能力要写入系统日历，请先允许日历访问。",
                        primaryButtonTitle: "请求权限",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .requestCalendarAccess
                    )
                )
            }

            return .blocked(
                gateKind: .systemPermission,
                reason: "日历权限不可用，请到系统设置开启。",
                prompt: MagicianPermissionPromptModel(
                    feature: feature,
                    title: "需要日历权限",
                    message: "日历能力要写入系统日历，请到系统设置开启日历权限。",
                    primaryButtonTitle: "打开系统设置",
                    secondaryButtonTitle: "稍后再说",
                    primaryAction: .openSystemSettings(
                        urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                    )
                )
            )

        case .markdownDocument:
            return .ready

        case .mail:
            guard
                dependencies.composeEmailAvailable
                    || dependencies.mailtoAvailable
                    || dependencies.mailAppAvailable
            else {
                return .blocked(
                    gateKind: .serviceDependency,
                    reason: "当前无法使用邮件，请先打开 Mail 并完成账号配置。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "邮件服务不可用",
                        message: "邮件能力依赖系统 Mail。请先打开 Mail，并确认系统里已经配置好可用账号。",
                        primaryButtonTitle: "打开 Mail",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .openMailApp
                    )
                )
            }
            return .ready

        case .music:
            guard dependencies.musicAppAvailable else {
                return .blocked(
                    gateKind: .serviceDependency,
                    reason: "音乐应用不可用，请先打开 Music。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "Music 不可用",
                        message: "音乐能力依赖系统 Music。请先打开 Music 应用后再试。",
                        primaryButtonTitle: "打开 Music",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .openMusicApp
                    )
                )
            }
            return .ready

        case .clock:
            switch dependencies.notificationAuthorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            case .notDetermined:
                return .blocked(
                    gateKind: .systemPermission,
                    reason: "需要先允许通知权限，时钟提醒才有保证路径。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "需要通知权限",
                        message: "时钟能力的稳定路径是本地提醒，请先允许通知权限。",
                        primaryButtonTitle: "请求权限",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .requestNotificationAccess
                    )
                )
            case .denied, .unknown:
                return .blocked(
                    gateKind: .systemPermission,
                    reason: "通知权限没开，时钟提醒无法稳定生效。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "需要通知权限",
                        message: "请先在系统设置里打开通知权限，这样本地提醒才能正常工作。",
                        primaryButtonTitle: "打开系统设置",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .openSystemSettings(
                            urlString: "x-apple.systempreferences:com.apple.preference.notifications"
                        )
                    )
                )
            }

            guard dependencies.clockHandoffAvailable else {
                return .blocked(
                    gateKind: .serviceDependency,
                    reason: "当前系统没有可用的 Clock handoff，无法把你带到闹钟或计时器入口。",
                    prompt: MagicianPermissionPromptModel(
                        feature: feature,
                        title: "Clock 不可用",
                        message: "这台 Mac 暂时没有可用的 Clock.app 或相关入口，所以只能保留提醒路径。",
                        primaryButtonTitle: "打开 Clock",
                        secondaryButtonTitle: "稍后再说",
                        primaryAction: .openClockApp(surface: .worldClock)
                    )
                )
            }
            return .ready

        case .feishuCLI:
            return .ready

        case .createEvent, .createNote, .composeEmailDraft, .controlMusic:
            return requirement(for: feature.canonicalFeature, dependencies: dependencies)
        }
    }

    private func hasEventAccess(_ status: EKAuthorizationStatus) -> Bool {
        status == .fullAccess || status == .writeOnly
    }
}

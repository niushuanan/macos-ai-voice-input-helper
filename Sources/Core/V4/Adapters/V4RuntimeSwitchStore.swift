import Foundation

enum V4RuntimeRoute: Equatable {
    case v4
    case legacyNative
    case legacyAgent

    var runtimeVersion: Int {
        switch self {
        case .v4:
            return 4
        case .legacyNative:
            return 2
        case .legacyAgent:
            return 3
        }
    }
}

struct V4RuntimeSwitchStore {
    static let legacyRuntimeDefaultsKey = "magician.debug.useLegacyRuntime"
    static let legacyRuntimeEnvironmentKey = "PULSETYPE_MAGICIAN_USE_LEGACY_RUNTIME"

    let defaults: UserDefaults
    let environment: [String: String]

    init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.environment = environment
    }

    var isLegacyRuntimeEnabled: Bool {
        truthy(environment[Self.legacyRuntimeEnvironmentKey])
            || defaults.bool(forKey: Self.legacyRuntimeDefaultsKey)
    }

    func route(for laneDecision: MagicianLaneDecision) -> V4RuntimeRoute {
        guard isLegacyRuntimeEnabled else {
            return .v4
        }

        switch laneDecision.lane {
        case .nativeFast:
            return .legacyNative
        case .agent:
            return .legacyAgent
        }
    }

    var defaultRuntimeVersion: Int {
        // 预检失败尚未进入 legacy runtime，本窗统一按 V4 默认主链记为 4。
        4
    }

    private func truthy(_ value: String?) -> Bool {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return false
        }

        switch normalized {
        case "1", "true", "yes", "on", "debug", "legacy":
            return true
        default:
            return false
        }
    }
}

@MainActor
protocol LegacyMagicianRuntimeResolving {
    func runtime(for route: V4RuntimeRoute) -> (any MagicianAgentRunning)?
}

@MainActor
final class LegacyMagicianRuntimeResolver: LegacyMagicianRuntimeResolving {
    private let providerSettingsStore: ProviderSettingsStore
    private let rewriteProviderRegistry: RewriteProviderRegistry
    private let textOutputCoordinator: TextOutputCoordinator
    private let skillRuleStore: SkillRuleStore
    private let mailAddressBookStore: MailAddressBookStore
    private var legacyToolExecutor: (any MagicianToolExecuting)?
    private var magicianNativeRuntime: (any MagicianAgentRunning)?
    private var magicianAgentRuntime: (any MagicianAgentRunning)?

    init(
        providerSettingsStore: ProviderSettingsStore,
        rewriteProviderRegistry: RewriteProviderRegistry,
        textOutputCoordinator: TextOutputCoordinator,
        skillRuleStore: SkillRuleStore,
        mailAddressBookStore: MailAddressBookStore? = nil,
        magicianToolExecutor: (any MagicianToolExecuting)? = nil,
        magicianNativeRuntime: (any MagicianAgentRunning)? = nil,
        magicianAgentRuntime: (any MagicianAgentRunning)? = nil
    ) {
        self.providerSettingsStore = providerSettingsStore
        self.rewriteProviderRegistry = rewriteProviderRegistry
        self.textOutputCoordinator = textOutputCoordinator
        self.skillRuleStore = skillRuleStore
        self.mailAddressBookStore = mailAddressBookStore ?? MailAddressBookStore()
        self.legacyToolExecutor = magicianToolExecutor
        self.magicianNativeRuntime = magicianNativeRuntime
        self.magicianAgentRuntime = magicianAgentRuntime
    }

    func runtime(for route: V4RuntimeRoute) -> (any MagicianAgentRunning)? {
        switch route {
        case .legacyNative:
            if let magicianNativeRuntime {
                return magicianNativeRuntime
            }
            let runtime = MagicianNativeRuntime(
                providerSettingsStore: providerSettingsStore,
                rewriteProviderRegistry: rewriteProviderRegistry,
                textOutputCoordinator: textOutputCoordinator,
                skillRuleStore: skillRuleStore,
                toolExecutor: resolveToolExecutor()
            )
            magicianNativeRuntime = runtime
            return runtime

        case .legacyAgent:
            if let magicianAgentRuntime {
                return magicianAgentRuntime
            }
            let runtime = MagicianAgentRuntimeV3(
                providerSettingsStore: providerSettingsStore,
                rewriteProviderRegistry: rewriteProviderRegistry,
                textOutputCoordinator: textOutputCoordinator,
                skillRuleStore: skillRuleStore,
                toolExecutor: resolveToolExecutor()
            )
            magicianAgentRuntime = runtime
            return runtime

        case .v4:
            return nil
        }
    }

    private func resolveToolExecutor() -> any MagicianToolExecuting {
        if let legacyToolExecutor {
            return legacyToolExecutor
        }
        let executor = MagicianToolExecutor(
            providerSettingsStore: providerSettingsStore,
            mailAddressBookStore: mailAddressBookStore
        )
        legacyToolExecutor = executor
        return executor
    }
}

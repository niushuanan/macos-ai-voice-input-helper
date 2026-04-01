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
        case .agent, .unsupportedMixedExternal:
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

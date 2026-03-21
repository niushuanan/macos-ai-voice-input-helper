import Foundation

enum AppOutputBias: String, Codable, CaseIterable, Identifiable {
    case neutral
    case formal
    case casual
    case structured

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .neutral:
            return "Neutral"
        case .formal:
            return "Formal"
        case .casual:
            return "Casual"
        case .structured:
            return "Structured"
        }
    }

    var rewritePolishStyle: RewritePolishStyle {
        switch self {
        case .neutral:
            return .neutral
        case .formal:
            return .formal
        case .casual:
            return .casual
        case .structured:
            return .neutral
        }
    }
}

struct AppScenePolicy: Identifiable, Codable, Equatable {
    let id: String
    var appName: String
    var bundleID: String
    var outputBias: AppOutputBias
    var preferSelectionRewrite: Bool

    init(
        appName: String,
        bundleID: String,
        outputBias: AppOutputBias,
        preferSelectionRewrite: Bool
    ) {
        self.id = bundleID
        self.appName = appName
        self.bundleID = bundleID
        self.outputBias = outputBias
        self.preferSelectionRewrite = preferSelectionRewrite
    }
}

@MainActor
final class AppScenePolicyStore: ObservableObject {
    @Published private(set) var policies: [AppScenePolicy]

    private let defaults: UserDefaults
    private let storageKey = "scene.policy.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.policies = AppScenePolicyStore.loadPolicies(defaults: defaults)
    }

    func policy(for context: FocusedAppContext) -> AppScenePolicy {
        if let existing = policies.first(where: { $0.bundleID == context.bundleID }) {
            return existing
        }
        return heuristicPolicy(for: context)
    }

    func hasStoredPolicy(bundleID: String) -> Bool {
        policies.contains { $0.bundleID == bundleID }
    }

    func upsertPolicy(
        for context: FocusedAppContext,
        outputBias: AppOutputBias,
        preferSelectionRewrite: Bool
    ) {
        let next = AppScenePolicy(
            appName: context.appName,
            bundleID: context.bundleID,
            outputBias: outputBias,
            preferSelectionRewrite: preferSelectionRewrite
        )

        if let index = policies.firstIndex(where: { $0.bundleID == context.bundleID }) {
            policies[index] = next
        } else {
            policies.append(next)
        }
        persist()
    }

    func upsertPolicy(
        appName: String,
        bundleID: String,
        outputBias: AppOutputBias,
        preferSelectionRewrite: Bool
    ) {
        let context = FocusedAppContext(
            appName: appName,
            bundleID: bundleID,
            focusedRole: nil,
            hasEditableTarget: true,
            strategyHint: ""
        )
        upsertPolicy(
            for: context,
            outputBias: outputBias,
            preferSelectionRewrite: preferSelectionRewrite
        )
    }

    func removePolicy(bundleID: String) {
        policies.removeAll { $0.bundleID == bundleID }
        persist()
    }

    private func heuristicPolicy(for context: FocusedAppContext) -> AppScenePolicy {
        let bundleID = context.bundleID.lowercased()

        if bundleID.contains("mail") || bundleID.contains("pages") {
            return AppScenePolicy(
                appName: context.appName,
                bundleID: context.bundleID,
                outputBias: .formal,
                preferSelectionRewrite: true
            )
        }

        if bundleID.contains("slack") || bundleID.contains("discord") || bundleID.contains("wechat") {
            return AppScenePolicy(
                appName: context.appName,
                bundleID: context.bundleID,
                outputBias: .casual,
                preferSelectionRewrite: false
            )
        }

        if bundleID.contains("notion") || bundleID.contains("obsidian") || bundleID.contains("notes") {
            return AppScenePolicy(
                appName: context.appName,
                bundleID: context.bundleID,
                outputBias: .structured,
                preferSelectionRewrite: true
            )
        }

        return AppScenePolicy(
            appName: context.appName,
            bundleID: context.bundleID,
            outputBias: .neutral,
            preferSelectionRewrite: true
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(policies) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private static func loadPolicies(defaults: UserDefaults) -> [AppScenePolicy] {
        guard
            let data = defaults.data(forKey: "scene.policy.v1"),
            let decoded = try? JSONDecoder().decode([AppScenePolicy].self, from: data)
        else {
            return []
        }
        return decoded
    }
}

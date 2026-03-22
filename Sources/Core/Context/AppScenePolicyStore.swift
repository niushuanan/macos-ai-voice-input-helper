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
            return "中性"
        case .formal:
            return "正式"
        case .casual:
            return "口语"
        case .structured:
            return "结构化"
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

    var legacyPromptHint: String {
        switch self {
        case .neutral:
            return ""
        case .formal:
            return "请使用更正式、专业的语气。"
        case .casual:
            return "请使用更自然、口语化的表达。"
        case .structured:
            return "请优先按清晰结构组织内容，必要时分点表达。"
        }
    }
}

struct AppScenePolicy: Identifiable, Codable, Equatable {
    let id: String
    var appName: String
    var bundleID: String
    var appPrompt: String

    init(
        appName: String,
        bundleID: String,
        appPrompt: String
    ) {
        self.id = bundleID
        self.appName = appName
        self.bundleID = bundleID
        self.appPrompt = appPrompt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case appName
        case bundleID
        case appPrompt
        case outputBias
        case preferSelectionRewrite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedBundleID = try container.decode(String.self, forKey: .bundleID)
        let decodedName = try container.decode(String.self, forKey: .appName)
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id) ?? decodedBundleID

        let promptFromStorage = try container.decodeIfPresent(String.self, forKey: .appPrompt)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let legacyBias = try container.decodeIfPresent(AppOutputBias.self, forKey: .outputBias) ?? .neutral
        let migratedPrompt = promptFromStorage.isEmpty ? legacyBias.legacyPromptHint : promptFromStorage

        self.id = decodedID
        self.appName = decodedName
        self.bundleID = decodedBundleID
        self.appPrompt = migratedPrompt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(appName, forKey: .appName)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(appPrompt.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .appPrompt)
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
        appPrompt: String
    ) {
        let next = AppScenePolicy(
            appName: context.appName,
            bundleID: context.bundleID,
            appPrompt: appPrompt
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
        appPrompt: String
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
            appPrompt: appPrompt
        )
    }

    func removePolicy(bundleID: String) {
        policies.removeAll { $0.bundleID == bundleID }
        persist()
    }

    private func heuristicPolicy(for context: FocusedAppContext) -> AppScenePolicy {
        return AppScenePolicy(
            appName: context.appName,
            bundleID: context.bundleID,
            appPrompt: ""
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

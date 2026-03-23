import AppKit
import Foundation

enum SceneAppCandidatePriority: Int, Comparable {
    case installed = 0
    case runningInputMethod = 1
    case runningRegular = 2

    static func < (lhs: SceneAppCandidatePriority, rhs: SceneAppCandidatePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum SceneAppCandidateSource: Equatable {
    case running(activationPolicy: NSApplication.ActivationPolicy)
    case installed
}

struct SceneAppOption: Identifiable, Hashable {
    let appName: String
    let bundleID: String
    let sourcePriority: SceneAppCandidatePriority

    var id: String { bundleID }
}

enum SceneAppDiscovery {
    static let excludedKeywordTokens: [String] = [
        "helper",
        "renderer",
        "networking",
        "gpu",
        "webcontent",
        "plugin",
        "daemon",
        "agent",
        "updater"
    ]

    static func upsertCandidate(
        appName: String,
        bundleID: String,
        source: SceneAppCandidateSource,
        selfBundleID: String?,
        map: inout [String: SceneAppOption]
    ) {
        let normalizedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBundle.isEmpty else {
            return
        }
        guard normalizedBundle != selfBundleID else {
            return
        }
        guard shouldIncludeCandidate(appName: appName, bundleID: normalizedBundle) else {
            return
        }
        guard let priority = priority(for: source, bundleID: normalizedBundle) else {
            return
        }

        let candidate = SceneAppOption(
            appName: appName,
            bundleID: normalizedBundle,
            sourcePriority: priority
        )

        guard let existing = map[normalizedBundle] else {
            map[normalizedBundle] = candidate
            return
        }

        if candidate.sourcePriority > existing.sourcePriority {
            map[normalizedBundle] = candidate
            return
        }

        if
            candidate.sourcePriority == existing.sourcePriority,
            candidate.appName.localizedCompare(existing.appName) == .orderedAscending
        {
            map[normalizedBundle] = candidate
        }
    }

    static func priority(
        for source: SceneAppCandidateSource,
        bundleID: String
    ) -> SceneAppCandidatePriority? {
        switch source {
        case .installed:
            return .installed
        case let .running(activationPolicy):
            if activationPolicy == .regular {
                return .runningRegular
            }
            if isInputMethodBundle(bundleID) {
                return .runningInputMethod
            }
            return nil
        }
    }

    static func shouldIncludeCandidate(appName: String, bundleID: String) -> Bool {
        !shouldExcludeCandidate(appName: appName, bundleID: bundleID)
    }

    static func shouldExcludeCandidate(appName: String, bundleID: String) -> Bool {
        if isInputMethodBundle(bundleID) {
            return false
        }

        let normalizedName = appName.lowercased()
        let normalizedBundle = bundleID.lowercased()
        return excludedKeywordTokens.contains { token in
            normalizedBundle.contains(token) || normalizedName.contains(token)
        }
    }

    static func isInputMethodBundle(_ bundleID: String) -> Bool {
        let normalized = bundleID.lowercased()
        return normalized.contains("inputmethod")
            || normalized == "com.tencent.inputmethod.wetype"
    }
}

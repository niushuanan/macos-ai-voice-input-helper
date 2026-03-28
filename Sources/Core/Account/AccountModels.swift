import Foundation

enum AccountEdition: String, Codable, CaseIterable {
    case free
    case member
    case professional

    var displayTitle: String {
        switch self {
        case .free:
            return "免费版"
        case .member:
            return "会员版"
        case .professional:
            return "专业版"
        }
    }
}

enum AccountAuthChannel: String, Codable {
    case email
    case phone
}

enum AccountLifecycleStatus: String, Codable {
    case active
    case pending
    case disabled
}

enum AccountAuthState: Equatable {
    case unavailable
    case signedOut
    case sendingCode(email: String)
    case codeSent(email: String, resendAvailableAt: Date)
    case verifying(email: String)
    case signedIn
}

@MainActor
protocol AccountAccessControlling: AnyObject {
    var isAuthenticated: Bool { get }
    func promptForAuthentication()
}

extension AccountAccessControlling {
    func promptForAuthentication() {}
}

enum AccountQuotaMetricKind: String, Codable, CaseIterable, Identifiable {
    case dictationCharacters = "dictation_chars"
    case magicianActions = "magician_actions"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictationCharacters:
            return "今日字数"
        case .magicianActions:
            return "今日魔术先生"
        }
    }

    var unitTitle: String {
        switch self {
        case .dictationCharacters:
            return "字"
        case .magicianActions:
            return "次"
        }
    }
}

struct AccountQuotaMetric: Equatable, Identifiable {
    let kind: AccountQuotaMetricKind
    let remaining: Int?
    let total: Int?

    var id: String { kind.id }

    var summaryText: String {
        guard let remaining, let total else {
            return "不限额"
        }
        return "剩余 \(remaining)\(kind.unitTitle) / \(total)\(kind.unitTitle)"
    }

    var capsuleText: String {
        guard let remaining else {
            return "不限额"
        }
        return "今日剩余 \(remaining)"
    }
}

struct DailyUsageCounterSnapshot: Equatable {
    let kind: AccountQuotaMetricKind
    let usedCount: Int
    let limitCount: Int?
}

struct AccountQuotaSummary: Equatable {
    let primaryMetric: AccountQuotaMetric
    let metrics: [AccountQuotaMetric]

    static func resolved(
        for edition: AccountEdition,
        usageCounters: [DailyUsageCounterSnapshot]
    ) -> Self {
        let defaults = quotaDefaults(for: edition)
        let metrics = AccountQuotaMetricKind.allCases.map { kind in
            let usage = usageCounters.first(where: { $0.kind == kind })
            let defaultLimit = defaults[kind] ?? nil
            let limit = usage?.limitCount ?? defaultLimit
            let remaining: Int?
            if let limit {
                let usedCount = max(0, usage?.usedCount ?? 0)
                remaining = max(0, limit - usedCount)
            } else {
                remaining = nil
            }
            return AccountQuotaMetric(
                kind: kind,
                remaining: remaining,
                total: limit
            )
        }

        return AccountQuotaSummary(
            primaryMetric: metrics.first ?? AccountQuotaMetric(
                kind: .dictationCharacters,
                remaining: nil,
                total: nil
            ),
            metrics: metrics
        )
    }

    private static func quotaDefaults(
        for edition: AccountEdition
    ) -> [AccountQuotaMetricKind: Int?] {
        switch edition {
        case .free:
            return [
                .dictationCharacters: 1_000,
                .magicianActions: 3
            ]
        case .member:
            return [
                .dictationCharacters: 10_000,
                .magicianActions: 50
            ]
        case .professional:
            return [
                .dictationCharacters: nil,
                .magicianActions: nil
            ]
        }
    }
}

struct AccountSummary: Equatable {
    let userID: UUID
    let email: String
    let edition: AccountEdition
    let authChannel: AccountAuthChannel
    let lifecycleStatus: AccountLifecycleStatus
    let lastLoginAt: Date?
    let quotaSummary: AccountQuotaSummary

    var capsuleTitle: String {
        switch edition {
        case .professional:
            return "\(edition.displayTitle) · 不限额"
        case .free, .member:
            return "\(edition.displayTitle) · \(quotaSummary.primaryMetric.capsuleText)"
        }
    }
}

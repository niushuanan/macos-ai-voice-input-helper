import Foundation
import Supabase

enum AccountServiceError: LocalizedError {
    case notConfigured
    case sessionMissing
    case profileMissing

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "当前还没配置 Supabase，请先补齐 project URL 和 anon key。"
        case .sessionMissing:
            return "当前没有可用登录态。"
        case .profileMissing:
            return "当前账号还没有同步到用户资料表。"
        }
    }
}

@MainActor
final class SupabaseAccountService {
    private let client: SupabaseClient?
    private let deviceInstallationStore: DeviceInstallationStore

    init(
        configuration: SupabaseRuntimeConfiguration?,
        deviceInstallationStore: DeviceInstallationStore = DeviceInstallationStore()
    ) {
        self.deviceInstallationStore = deviceInstallationStore

        if let configuration {
            let configuredClient = SupabaseClient(
                supabaseURL: configuration.url,
                supabaseKey: configuration.anonKey,
                options: SupabaseClientOptions(
                    auth: .init(
                        storage: SupabaseAuthSessionStorage(),
                        storageKey: configuration.authStorageKey,
                        autoRefreshToken: true,
                        emitLocalSessionAsInitialSession: true
                    )
                )
            )
            client = configuredClient
            Task {
                await configuredClient.auth.startAutoRefresh()
            }
        } else {
            client = nil
        }
    }

    var isConfigured: Bool {
        client != nil
    }

    var authStateChanges: AsyncStream<(event: AuthChangeEvent, session: Session?)>? {
        client?.auth.authStateChanges
    }

    var hasCurrentSession: Bool {
        client?.auth.currentSession != nil
    }

    func startEmailOTP(email: String) async throws {
        guard let client else {
            throw AccountServiceError.notConfigured
        }
        try await client.auth.signInWithOTP(
            email: email,
            shouldCreateUser: true
        )
    }

    func verifyEmailOTP(email: String, token: String) async throws -> AccountSummary {
        guard let client else {
            throw AccountServiceError.notConfigured
        }

        _ = try await client.auth.verifyOTP(
            email: email,
            token: token,
            type: .email
        )

        guard let summary = try await fetchCurrentSummary(required: true) else {
            throw AccountServiceError.profileMissing
        }
        return summary
    }

    func restoreSession() async throws -> AccountSummary? {
        guard let client else {
            return nil
        }
        do {
            _ = try await client.auth.session
        } catch {
            return nil
        }
        return try await fetchCurrentSummary(required: true)
    }

    func fetchCurrentSummary(required: Bool = false) async throws -> AccountSummary? {
        guard let client else {
            return nil
        }

        guard let user = try? await client.auth.session.user else {
            if required {
                throw AccountServiceError.sessionMissing
            }
            return nil
        }

        try await syncProfile(for: user)
        try await syncDevice(for: user)
        return try await querySummary(for: user)
    }

    func signOut() async throws {
        guard let client else {
            return
        }
        try await client.auth.signOut()
    }

    private func syncProfile(for user: User) async throws {
        guard let client else {
            return
        }

        let patch = ProfileUpdatePayload(
            contactEmail: user.email,
            lastLoginAt: Date()
        )
        _ = try await client
            .from("profiles")
            .update(patch)
            .eq("id", value: user.id)
            .execute()
    }

    private func syncDevice(for user: User) async throws {
        guard let client else {
            return
        }

        let payload = UserDevicePayload(
            userID: user.id,
            installationID: deviceInstallationStore.installationID(),
            deviceName: deviceInstallationStore.deviceName,
            platform: deviceInstallationStore.platformName,
            appVersion: deviceInstallationStore.appVersionLine,
            lastSeenAt: Date()
        )

        _ = try await client
            .from("user_devices")
            .upsert(
                payload,
                onConflict: "user_id,installation_id"
            )
            .execute()
    }

    private func querySummary(for user: User) async throws -> AccountSummary {
        guard let client else {
            throw AccountServiceError.notConfigured
        }

        let profile: ProfileRow = try await client
            .from("profiles")
            .select()
            .eq("id", value: user.id)
            .single()
            .execute()
            .value

        let usageCounters: [DailyUsageCounterRow] = try await client
            .from("daily_usage_counters")
            .select()
            .eq("user_id", value: user.id)
            .eq("counter_date", value: Self.counterDateString(for: Date()))
            .execute()
            .value

        let edition = AccountEdition(rawValue: profile.edition) ?? .professional
        let authChannel = AccountAuthChannel(rawValue: profile.authChannel) ?? .email
        let lifecycleStatus = AccountLifecycleStatus(rawValue: profile.accountStatus) ?? .active
        let quotaSummary = AccountQuotaSummary.resolved(
            for: edition,
            usageCounters: usageCounters.compactMap {
                guard let kind = AccountQuotaMetricKind(rawValue: $0.counterKey) else {
                    return nil
                }
                return DailyUsageCounterSnapshot(
                    kind: kind,
                    usedCount: $0.usedCount,
                    limitCount: $0.limitCount
                )
            }
        )

        return AccountSummary(
            userID: profile.id,
            email: profile.contactEmail ?? user.email ?? "",
            edition: edition,
            authChannel: authChannel,
            lifecycleStatus: lifecycleStatus,
            lastLoginAt: profile.lastLoginAt,
            quotaSummary: quotaSummary
        )
    }

    private static func counterDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct ProfileRow: Decodable {
    let id: UUID
    let authChannel: String
    let contactEmail: String?
    let edition: String
    let accountStatus: String
    let lastLoginAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case authChannel = "auth_channel"
        case contactEmail = "contact_email"
        case edition
        case accountStatus = "account_status"
        case lastLoginAt = "last_login_at"
    }
}

private struct DailyUsageCounterRow: Decodable {
    let counterKey: String
    let usedCount: Int
    let limitCount: Int?

    enum CodingKeys: String, CodingKey {
        case counterKey = "counter_key"
        case usedCount = "used_count"
        case limitCount = "limit_count"
    }
}

private struct ProfileUpdatePayload: Encodable {
    let contactEmail: String?
    let lastLoginAt: Date

    enum CodingKeys: String, CodingKey {
        case contactEmail = "contact_email"
        case lastLoginAt = "last_login_at"
    }
}

private struct UserDevicePayload: Encodable {
    let userID: UUID
    let installationID: UUID
    let deviceName: String
    let platform: String
    let appVersion: String
    let lastSeenAt: Date

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case installationID = "installation_id"
        case deviceName = "device_name"
        case platform
        case appVersion = "app_version"
        case lastSeenAt = "last_seen_at"
    }
}

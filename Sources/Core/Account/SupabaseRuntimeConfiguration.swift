import Foundation

struct SupabaseRuntimeConfiguration: Equatable {
    let url: URL
    let anonKey: String
    let authStorageKey: String

    static let urlInfoKey = "PULSETYPE_SUPABASE_URL"
    static let anonKeyInfoKey = "PULSETYPE_SUPABASE_ANON_KEY"
    static let authStorageKeyDefaultValue = "pulsetype.auth.session"
    static let bundledURL = "https://agacevqkmetfimxbdhgb.supabase.co"
    static let bundledAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFnYWNldnFrbWV0ZmlteGJkaGdiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMzODEwMTAsImV4cCI6MjA4ODk1NzAxMH0.5JX9cUU9KSPXZ7CLnLS9_3x9Ra_X7whhvSjI0MZBYWg"
    private static let legacyURLKeys = ["SUPABASE_URL"]
    private static let legacyAnonKeyKeys = ["SUPABASE_ANON_KEY"]

    static func current(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> SupabaseRuntimeConfiguration? {
        let readsUserDefaults = environment["XCTestConfigurationFilePath"] == nil

        let resolvedURLString = resolvedValue(
            primaryKey: urlInfoKey,
            fallbackKeys: legacyURLKeys,
            bundle: bundle,
            environment: environment,
            userDefaults: userDefaults,
            readsUserDefaults: readsUserDefaults
        )
        let anonKey = resolvedValue(
            primaryKey: anonKeyInfoKey,
            fallbackKeys: legacyAnonKeyKeys,
            bundle: bundle,
            environment: environment,
            userDefaults: userDefaults,
            readsUserDefaults: readsUserDefaults
        ) ?? bundledAnonKey

        guard
            let url = validatedSupabaseURL(from: resolvedURLString) ??
                validatedSupabaseURL(from: bundledURL),
            !anonKey.isEmpty
        else {
            return nil
        }

        return SupabaseRuntimeConfiguration(
            url: url,
            anonKey: anonKey,
            authStorageKey: authStorageKeyDefaultValue
        )
    }

    private static func resolvedValue(
        primaryKey: String,
        fallbackKeys: [String],
        bundle: Bundle,
        environment: [String: String],
        userDefaults: UserDefaults,
        readsUserDefaults: Bool
    ) -> String? {
        let keys = [primaryKey] + fallbackKeys

        for key in keys {
            if let normalized = normalizedValue(environment[key]) {
                return normalized
            }
        }

        if readsUserDefaults {
            for key in keys {
                if let normalized = normalizedValue(userDefaults.string(forKey: key)) {
                    return normalized
                }
            }
        }

        guard
            let value = bundle.object(forInfoDictionaryKey: primaryKey) as? String
        else {
            return nil
        }

        return normalizedValue(value)
    }

    private static func validatedSupabaseURL(from rawValue: String?) -> URL? {
        guard
            let rawValue,
            let url = URL(string: rawValue),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            return nil
        }
        return url
    }

    private static func normalizedValue(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalized.isEmpty,
            !normalized.contains("$("),
            !normalized.contains("${")
        else {
            return nil
        }
        return normalized
    }
}

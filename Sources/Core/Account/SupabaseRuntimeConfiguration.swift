import Foundation

struct SupabaseRuntimeConfiguration: Equatable {
    let url: URL
    let anonKey: String
    let authStorageKey: String

    static let urlInfoKey = "PULSETYPE_SUPABASE_URL"
    static let anonKeyInfoKey = "PULSETYPE_SUPABASE_ANON_KEY"
    static let authStorageKeyDefaultValue = "pulsetype.auth.session"

    static func current(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SupabaseRuntimeConfiguration? {
        let urlString = resolvedValue(
            key: urlInfoKey,
            bundle: bundle,
            environment: environment
        )
        let anonKey = resolvedValue(
            key: anonKeyInfoKey,
            bundle: bundle,
            environment: environment
        )

        guard
            let urlString,
            let anonKey,
            let url = URL(string: urlString),
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
        key: String,
        bundle: Bundle,
        environment: [String: String]
    ) -> String? {
        if let normalized = normalizedValue(environment[key]) {
            return normalized
        }

        guard
            let value = bundle.object(forInfoDictionaryKey: key) as? String
        else {
            return nil
        }

        return normalizedValue(value)
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

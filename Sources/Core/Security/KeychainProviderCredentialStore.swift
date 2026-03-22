import Foundation
import Security

final class KeychainProviderCredentialStore: ProviderCredentialStore {
    private let service: String

    init(service: String = "com.niushuanan.PulseType.provider-profile.v4") {
        self.service = service
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        var query = baseQuery(profileID: profileID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        let (status, item) = copyMatching(query: query, allowUserInteraction: true)
        switch status {
        case errSecSuccess:
            guard
                let data = item as? Data,
                let value = String(data: data, encoding: .utf8)
            else {
                throw ProviderCredentialStoreError.invalidCredentialEncoding
            }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw ProviderCredentialStoreError.interactionRequired
        default:
            throw ProviderCredentialStoreError.unexpectedStatus(status)
        }
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            try deleteAPIKey(for: profileID)
            return
        }

        try deleteAPIKey(for: profileID)

        var query = baseQuery(profileID: profileID)
        query[kSecValueData as String] = Data(normalized.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let (status, _) = add(query: query)
        guard status == errSecSuccess else {
            throw ProviderCredentialStoreError.unexpectedStatus(status)
        }
    }

    func deleteAPIKey(for profileID: String) throws {
        let status = delete(query: baseQuery(profileID: profileID))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderCredentialStoreError.unexpectedStatus(status)
        }
    }

    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool {
        var query = baseQuery(profileID: profileID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true

        let (status, _) = copyMatching(
            query: query,
            allowUserInteraction: allowUserInteraction
        )

        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        case errSecInteractionNotAllowed:
            throw ProviderCredentialStoreError.interactionRequired
        default:
            throw ProviderCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(profileID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func copyMatching(
        query: [String: Any],
        allowUserInteraction: Bool
    ) -> (OSStatus, CFTypeRef?) {
        var adjustedQuery = query
        if !allowUserInteraction {
            adjustedQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var item: CFTypeRef?
        var status = SecItemCopyMatching(adjustedQuery as CFDictionary, &item)
        if status == errSecParam {
            adjustedQuery = fallbackQueryWithoutDataProtection(adjustedQuery)
            status = SecItemCopyMatching(adjustedQuery as CFDictionary, &item)
        }
        return (status, item)
    }

    private func add(query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var item: CFTypeRef?
        var status = SecItemAdd(query as CFDictionary, &item)
        if status == errSecParam {
            let fallbackQuery = fallbackQueryWithoutDataProtection(query)
            status = SecItemAdd(fallbackQuery as CFDictionary, &item)
        }
        return (status, item)
    }

    private func delete(query: [String: Any]) -> OSStatus {
        var status = SecItemDelete(query as CFDictionary)
        if status == errSecParam {
            let fallbackQuery = fallbackQueryWithoutDataProtection(query)
            status = SecItemDelete(fallbackQuery as CFDictionary)
        }
        return status
    }

    private func fallbackQueryWithoutDataProtection(
        _ query: [String: Any]
    ) -> [String: Any] {
        var fallback = query
        fallback.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        return fallback
    }
}

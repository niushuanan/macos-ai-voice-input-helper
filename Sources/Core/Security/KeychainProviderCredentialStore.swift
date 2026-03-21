import Foundation
import Security

final class KeychainProviderCredentialStore: ProviderCredentialStore {
    private let service: String
    private let legacyServices: [String]

    init(
        service: String = "com.niushuanan.PulseType.provider-profile.v2",
        legacyServices: [String] = ["com.niushuanan.PulseType.provider-profile"]
    ) {
        self.service = service
        self.legacyServices = legacyServices.filter { $0 != service }
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        if let value = try loadAPIKey(for: profileID, in: service, allowUserInteraction: true) {
            return value
        }

        for legacyService in legacyServices {
            guard let legacyValue = try loadAPIKey(
                for: profileID,
                in: legacyService,
                allowUserInteraction: true
            ) else {
                continue
            }

            do {
                try saveAPIKey(legacyValue, for: profileID)
                try deleteAPIKey(for: profileID, in: legacyService)
            } catch {
                // Best-effort migration; keep returning legacy value even if migration fails.
            }
            return legacyValue
        }

        return nil
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            try deleteAPIKey(for: profileID)
            return
        }

        let data = Data(normalized.utf8)
        // Recreate the keychain item so legacy ACL from old creator process does not linger.
        try deleteAPIKey(for: profileID, in: service)
        var addQuery = baseQuery(profileID: profileID, service: service)
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ProviderCredentialStoreError.unexpectedStatus(addStatus)
        }

        for legacyService in legacyServices {
            try deleteAPIKey(for: profileID, in: legacyService)
        }
    }

    func deleteAPIKey(for profileID: String) throws {
        try deleteAPIKey(for: profileID, in: service)
        for legacyService in legacyServices {
            try deleteAPIKey(for: profileID, in: legacyService)
        }
    }

    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool {
        do {
            if try containsAPIKey(for: profileID, in: service, allowUserInteraction: allowUserInteraction) {
                return true
            }
            for legacyService in legacyServices {
                if try containsAPIKey(
                    for: profileID,
                    in: legacyService,
                    allowUserInteraction: allowUserInteraction
                ) {
                    return true
                }
            }
            return false
        } catch let error as ProviderCredentialStoreError {
            throw error
        } catch {
            throw ProviderCredentialStoreError.unexpectedStatus(errSecInternalError)
        }
    }

    private func baseQuery(profileID: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID
        ]
    }

    private func loadAPIKey(
        for profileID: String,
        in service: String,
        allowUserInteraction: Bool
    ) throws -> String? {
        var query = baseQuery(profileID: profileID, service: service)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        if !allowUserInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard
                let data = item as? Data,
                let value = String(data: data, encoding: .utf8)
            else {
                throw ProviderCredentialStoreError.invalidCredentialEncoding
            }
            return value
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw ProviderCredentialStoreError.interactionRequired
        default:
            throw ProviderCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func deleteAPIKey(for profileID: String, in service: String) throws {
        let query = baseQuery(profileID: profileID, service: service)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func containsAPIKey(
        for profileID: String,
        in service: String,
        allowUserInteraction: Bool
    ) throws -> Bool {
        var query = baseQuery(profileID: profileID, service: service)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        if !allowUserInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
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
}

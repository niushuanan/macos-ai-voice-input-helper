import Foundation
import Security

final class KeychainProviderCredentialStore: ProviderCredentialStore {
    private let service: String

    init(service: String = "com.niushuanan.PulseType.provider-profile") {
        self.service = service
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        var query = baseQuery(profileID: profileID)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

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

        let data = Data(normalized.utf8)
        let query = baseQuery(profileID: profileID)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ProviderCredentialStoreError.unexpectedStatus(addStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw ProviderCredentialStoreError.unexpectedStatus(status)
        }
    }

    func deleteAPIKey(for profileID: String) throws {
        let query = baseQuery(profileID: profileID)
        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(profileID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID
        ]
    }
}

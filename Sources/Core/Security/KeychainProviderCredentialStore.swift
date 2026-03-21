import Foundation
import Security

final class KeychainProviderCredentialStore: ProviderCredentialStore {
    private let service: String

    init(service: String = "com.niushuanan.PulseType.transcription") {
        self.service = service
    }

    func loadAPIKey(for providerID: SpeechProviderID) throws -> String? {
        var query = baseQuery(providerID: providerID)
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

    func saveAPIKey(_ value: String, for providerID: SpeechProviderID) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            try deleteAPIKey(for: providerID)
            return
        }

        let data = Data(normalized.utf8)
        let query = baseQuery(providerID: providerID)
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

    func deleteAPIKey(for providerID: SpeechProviderID) throws {
        let query = baseQuery(providerID: providerID)
        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(providerID: SpeechProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.rawValue
        ]
    }
}

import Foundation
import LocalAuthentication
import Security

final class KeychainProviderCredentialStore: ProviderCredentialStore {
    private let service: String
    private let fallbackStatuses: Set<OSStatus> = [errSecParam, errSecMissingEntitlement]

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
            kSecAttrAccount as String: profileID
        ]
    }

    private func copyMatching(
        query: [String: Any],
        allowUserInteraction: Bool
    ) -> (OSStatus, CFTypeRef?) {
        var adjustedQuery = query
        if !allowUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            adjustedQuery[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        var status = SecItemCopyMatching(adjustedQuery as CFDictionary, &item)
        if shouldRetryWithoutDataProtection(for: status) {
            adjustedQuery = fallbackQueryWithoutDataProtection(adjustedQuery)
            status = SecItemCopyMatching(adjustedQuery as CFDictionary, &item)
        }
        return (status, item)
    }

    private func add(query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var item: CFTypeRef?
        var status = SecItemAdd(query as CFDictionary, &item)
        if shouldRetryWithoutDataProtection(for: status) {
            let fallbackQuery = fallbackQueryWithoutDataProtection(query)
            status = SecItemAdd(fallbackQuery as CFDictionary, &item)
        }
        return (status, item)
    }

    private func delete(query: [String: Any]) -> OSStatus {
        var status = SecItemDelete(query as CFDictionary)
        if shouldRetryWithoutDataProtection(for: status) {
            let fallbackQuery = fallbackQueryWithoutDataProtection(query)
            status = SecItemDelete(fallbackQuery as CFDictionary)
        }
        return status
    }

    private func shouldRetryWithoutDataProtection(for status: OSStatus) -> Bool {
        fallbackStatuses.contains(status)
    }

    private func fallbackQueryWithoutDataProtection(
        _ query: [String: Any]
    ) -> [String: Any] {
        var fallback = query
        fallback.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        return fallback
    }
}

final class LocalFileProviderCredentialStore: ProviderCredentialStore {
    private struct Payload: Codable {
        var values: [String: String]
    }

    private let fileManager: FileManager
    private let credentialsFileURL: URL
    private let lock = NSLock()
    private var values: [String: String]

    init(
        credentialsDirectory: URL,
        fileManager: FileManager = .default,
        legacyStores: [ProviderCredentialStore] = []
    ) {
        self.fileManager = fileManager
        self.credentialsFileURL = credentialsDirectory.appendingPathComponent(
            "credentials.v1.json",
            isDirectory: false
        )
        self.values = Self.loadValues(from: credentialsFileURL, fileManager: fileManager)
        ensureCredentialsDirectory(credentialsDirectory)
        migrateFromLegacyStoresIfNeeded(legacyStores)
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return normalizedValue(for: profileID)
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if normalized.isEmpty {
            values.removeValue(forKey: profileID)
        } else {
            values[profileID] = normalized
        }
        lock.unlock()
        try persistValues()
    }

    func deleteAPIKey(for profileID: String) throws {
        lock.lock()
        values.removeValue(forKey: profileID)
        lock.unlock()
        try persistValues()
    }

    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return normalizedValue(for: profileID) != nil
    }

    private func normalizedValue(for profileID: String) -> String? {
        guard
            let raw = values[profileID]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        return raw
    }

    private func ensureCredentialsDirectory(_ directory: URL) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            // Keep non-fatal to avoid blocking launch on permission metadata failures.
        }
    }

    private func migrateFromLegacyStoresIfNeeded(_ legacyStores: [ProviderCredentialStore]) {
        let profileIDs = ["asr.primary", "text.primary"]
        var didChange = false

        for profileID in profileIDs {
            if normalizedValue(for: profileID) != nil {
                continue
            }

            for legacyStore in legacyStores {
                guard
                    (try? legacyStore.containsAPIKey(
                        for: profileID,
                        allowUserInteraction: false
                    )) == true
                else {
                    continue
                }
                guard
                    let value = try? legacyStore.loadAPIKey(for: profileID)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    !value.isEmpty
                else {
                    continue
                }
                values[profileID] = value
                didChange = true
                break
            }
        }

        if didChange {
            try? persistValues()
        }
    }

    private func persistValues() throws {
        let payload = Payload(values: values)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: credentialsFileURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: credentialsFileURL.path
        )
    }

    private static func loadValues(from fileURL: URL, fileManager: FileManager) -> [String: String] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        guard
            let data = try? Data(contentsOf: fileURL),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return [:]
        }
        return payload.values
    }
}

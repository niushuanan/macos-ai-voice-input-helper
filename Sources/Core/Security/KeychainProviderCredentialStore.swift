import Foundation
import Security

final class KeychainProviderCredentialStore: ProviderCredentialStore {
    private let service: String
    private let cleanupServices: [String]

    init(
        service: String = "com.niushuanan.PulseType.provider-profile.v3",
        cleanupServices: [String] = [
            "com.niushuanan.PulseType.provider-profile.v2",
            "com.niushuanan.PulseType.provider-profile"
        ]
    ) {
        self.service = service
        self.cleanupServices = cleanupServices.filter { $0 != service }
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        try loadAPIKey(for: profileID, in: service, allowUserInteraction: true)
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
        if let access = makeTrustedAccess(profileID: profileID) {
            addQuery[kSecAttrAccess as String] = access
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ProviderCredentialStoreError.unexpectedStatus(addStatus)
        }

        for cleanupService in cleanupServices {
            try deleteAPIKey(for: profileID, in: cleanupService)
        }
    }

    func deleteAPIKey(for profileID: String) throws {
        try deleteAPIKey(for: profileID, in: service)
        for cleanupService in cleanupServices {
            try deleteAPIKey(for: profileID, in: cleanupService)
        }
    }

    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool {
        do {
            return try containsAPIKey(
                for: profileID,
                in: service,
                allowUserInteraction: allowUserInteraction
            )
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

    private func makeTrustedAccess(profileID: String) -> SecAccess? {
        var trustedApplications: [SecTrustedApplication] = []
        var seenPaths = Set<String>()

        for path in trustedApplicationPaths {
            guard seenPaths.insert(path).inserted else {
                continue
            }

            var trustedApp: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &trustedApp)
            if status == errSecSuccess, let trustedApp {
                trustedApplications.append(trustedApp)
            }
        }

        var currentApp: SecTrustedApplication?
        let currentStatus = SecTrustedApplicationCreateFromPath(nil, &currentApp)
        if currentStatus == errSecSuccess, let currentApp {
            trustedApplications.append(currentApp)
        }

        guard !trustedApplications.isEmpty else {
            return nil
        }

        let label = "\(service).\(profileID)" as CFString
        var access: SecAccess?
        let accessStatus = SecAccessCreate(label, trustedApplications as CFArray, &access)
        guard accessStatus == errSecSuccess else {
            return nil
        }
        return access
    }

    private var trustedApplicationPaths: [String] {
        var paths: [String] = ["/Applications/PulseType.app"]
        let mainPath = Bundle.main.bundlePath
        if !mainPath.isEmpty {
            paths.append(mainPath)
        }
        return paths
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

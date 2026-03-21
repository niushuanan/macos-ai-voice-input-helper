import Foundation
import Security

final class KeychainProviderCredentialStore: ProviderCredentialStore {
    private let service: String
    private let cleanupServices: [String]
    private let securityToolPath = "/usr/bin/security"

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
        do {
            return try loadAPIKey(
                for: profileID,
                in: service,
                allowUserInteraction: false
            )
        } catch ProviderCredentialStoreError.interactionRequired {
            // Fallback for local/dev updates where ACL can become inconsistent.
            let loaded = try loadAPIKeyViaSecurityTool(profileID: profileID, service: service)
            if let loaded, !loaded.isEmpty {
                try? saveViaSecurityTool(value: loaded, profileID: profileID, service: service)
            }
            return loaded
        }
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            try deleteAPIKey(for: profileID)
            return
        }

        do {
            try saveViaSecurityTool(value: normalized, profileID: profileID, service: service)
        } catch {
            // Security tool failed: fallback to Security.framework path.
            let data = Data(normalized.utf8)
            try deleteAPIKey(for: profileID, in: service)

            var addQuery = baseQuery(profileID: profileID, service: service)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

            var addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecParam {
                addQuery = fallbackQueryWithoutDataProtection(addQuery)
                addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            }
            guard addStatus == errSecSuccess else {
                throw ProviderCredentialStoreError.unexpectedStatus(addStatus)
            }
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
            kSecAttrAccount as String: profileID,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func fallbackQueryWithoutDataProtection(
        _ query: [String: Any]
    ) -> [String: Any] {
        var fallback = query
        fallback.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        return fallback
    }

    private func saveViaSecurityTool(
        value: String,
        profileID: String,
        service: String
    ) throws {
        let result = runSecurityCommand(arguments: [
            "add-generic-password",
            "-U",
            "-A",
            "-a", profileID,
            "-s", service,
            "-w", value
        ])
        guard result.exitCode == 0 else {
            throw ProviderCredentialStoreError.unexpectedStatus(errSecInternalError)
        }
    }

    private func loadAPIKeyViaSecurityTool(
        profileID: String,
        service: String
    ) throws -> String? {
        let result = runSecurityCommand(arguments: [
            "find-generic-password",
            "-a", profileID,
            "-s", service,
            "-w"
        ])

        switch result.exitCode {
        case 0:
            let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        case 44:
            return nil
        default:
            if result.stderr.localizedCaseInsensitiveContains("interaction") {
                throw ProviderCredentialStoreError.interactionRequired
            }
            throw ProviderCredentialStoreError.unexpectedStatus(errSecInternalError)
        }
    }

    private func runSecurityCommand(arguments: [String]) -> SecurityCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityToolPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return SecurityCommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(data: outputData, encoding: .utf8) ?? ""
        let errorText = String(data: errorData, encoding: .utf8) ?? ""

        return SecurityCommandResult(
            exitCode: process.terminationStatus,
            stdout: outputText,
            stderr: errorText
        )
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
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecParam {
            let fallbackQuery = fallbackQueryWithoutDataProtection(query)
            status = SecItemCopyMatching(fallbackQuery as CFDictionary, &item)
        }

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

        var status = SecItemDelete(query as CFDictionary)
        if status == errSecParam {
            let fallbackQuery = fallbackQueryWithoutDataProtection(query)
            status = SecItemDelete(fallbackQuery as CFDictionary)
        }

        if status == errSecItemNotFound {
            let result = runSecurityCommand(arguments: [
                "delete-generic-password",
                "-a", profileID,
                "-s", service
            ])
            if result.exitCode == 0 || result.exitCode == 44 {
                return
            }
        }

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
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecParam {
            let fallbackQuery = fallbackQueryWithoutDataProtection(query)
            status = SecItemCopyMatching(fallbackQuery as CFDictionary, &item)
        }

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

private struct SecurityCommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

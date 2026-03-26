import Foundation

enum CredentialStoreFactory {
    static let legacyKeychainServices = [
        "com.niushuanan.PulseType.provider-profile.v4",
        "com.niushuanan.PulseType.provider-profile.v3"
    ]

    static func makeProviderCredentialStore(
        credentialsDirectory: URL,
        fileManager: FileManager = .default,
        legacyStores: [ProviderCredentialStore]? = nil
    ) -> ProviderCredentialStore {
        LocalFileProviderCredentialStore(
            credentialsDirectory: credentialsDirectory,
            fileManager: fileManager,
            legacyStores: legacyStores ?? legacyKeychainServices.map { service in
                KeychainProviderCredentialStore(service: service)
            }
        )
    }
}

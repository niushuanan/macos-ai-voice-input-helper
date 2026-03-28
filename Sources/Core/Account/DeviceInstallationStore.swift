import Foundation

final class DeviceInstallationStore {
    private let credentialStore: KeychainProviderCredentialStore
    private let profileID: String
    private let bundle: Bundle

    init(
        credentialStore: KeychainProviderCredentialStore = KeychainProviderCredentialStore(
            service: "com.niushuanan.PulseType.installation.v1"
        ),
        profileID: String = "installation.primary",
        bundle: Bundle = .main
    ) {
        self.credentialStore = credentialStore
        self.profileID = profileID
        self.bundle = bundle
    }

    func installationID() -> UUID {
        if
            let existing = try? credentialStore.loadAPIKey(for: profileID),
            let uuid = UUID(uuidString: existing)
        {
            return uuid
        }

        let generated = UUID()
        try? credentialStore.saveAPIKey(generated.uuidString, for: profileID)
        return generated
    }

    var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    var platformName: String {
        "macOS"
    }

    var appVersionLine: String {
        let marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (marketingVersion, buildVersion) {
        case let (.some(marketing), .some(build)) where !marketing.isEmpty && !build.isEmpty:
            return "\(marketing) (\(build))"
        case let (.some(marketing), _):
            return marketing
        case let (_, .some(build)):
            return build
        default:
            return "unknown"
        }
    }
}

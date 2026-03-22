import Security
import XCTest
@testable import PulseType

final class KeychainProviderCredentialStoreTests: XCTestCase {
    func testSaveLoadDeleteRoundTripWorksInLocalBuildEnvironment() throws {
        let service = "com.niushuanan.PulseType.tests.keychain.\(UUID().uuidString)"
        let profileID = "asr.primary"
        let key = "sk-demo-\(UUID().uuidString)"
        let store = KeychainProviderCredentialStore(service: service)

        defer {
            try? store.deleteAPIKey(for: profileID)
        }

        XCTAssertNoThrow(try store.saveAPIKey(key, for: profileID))
        XCTAssertEqual(try store.loadAPIKey(for: profileID), key)
        XCTAssertEqual(try store.containsAPIKey(for: profileID, allowUserInteraction: false), true)

        XCTAssertNoThrow(try store.deleteAPIKey(for: profileID))
        XCTAssertEqual(try store.loadAPIKey(for: profileID), nil)
        XCTAssertEqual(try store.containsAPIKey(for: profileID, allowUserInteraction: false), false)
    }

    func testLocalFileStoreRoundTripAndDelete() throws {
        let credentialsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("credentials-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: credentialsDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: credentialsDirectory)
        }

        let store = LocalFileProviderCredentialStore(credentialsDirectory: credentialsDirectory)
        XCTAssertNil(try store.loadAPIKey(for: "text.primary"))

        try store.saveAPIKey(" sk-local-demo ", for: "text.primary")
        XCTAssertEqual(try store.loadAPIKey(for: "text.primary"), "sk-local-demo")
        XCTAssertEqual(try store.containsAPIKey(for: "text.primary", allowUserInteraction: false), true)

        try store.deleteAPIKey(for: "text.primary")
        XCTAssertNil(try store.loadAPIKey(for: "text.primary"))
    }

    func testLocalFileStoreMigratesLegacyStoreOnlyWhenNonInteractiveContainsPasses() throws {
        let credentialsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("credentials-migration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: credentialsDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: credentialsDirectory)
        }

        let legacy = LegacyCredentialStoreStub(
            values: ["text.primary": "sk-legacy-value"],
            containsByProfile: ["text.primary": true]
        )
        let store = LocalFileProviderCredentialStore(
            credentialsDirectory: credentialsDirectory,
            legacyStores: [legacy]
        )

        XCTAssertEqual(try store.loadAPIKey(for: "text.primary"), "sk-legacy-value")
        XCTAssertEqual(legacy.containsCallCount, 2)
        XCTAssertEqual(legacy.loadCallCount, 1)
    }
}

private final class LegacyCredentialStoreStub: ProviderCredentialStore {
    private let values: [String: String]
    private let containsByProfile: [String: Bool]

    private(set) var containsCallCount = 0
    private(set) var loadCallCount = 0

    init(values: [String: String], containsByProfile: [String: Bool]) {
        self.values = values
        self.containsByProfile = containsByProfile
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        loadCallCount += 1
        return values[profileID]
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {}

    func deleteAPIKey(for profileID: String) throws {}

    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool {
        containsCallCount += 1
        return containsByProfile[profileID] ?? false
    }
}

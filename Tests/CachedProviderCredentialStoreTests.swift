import XCTest
@testable import PulseType

final class CachedProviderCredentialStoreTests: XCTestCase {
    func testRepeatedLoadHitsUpstreamOnlyOnce() throws {
        let upstream = CountingCredentialStore()
        try upstream.saveAPIKey("sk-demo-001", for: "asr.primary")
        let cache = CachedProviderCredentialStore(upstream: upstream)

        let first = try cache.loadAPIKey(for: "asr.primary")
        let second = try cache.loadAPIKey(for: "asr.primary")

        XCTAssertEqual(first, "sk-demo-001")
        XCTAssertEqual(second, "sk-demo-001")
        XCTAssertEqual(upstream.loadCount, 1)
    }

    func testSaveUpdatesCacheWithoutExtraRead() throws {
        let upstream = CountingCredentialStore()
        let cache = CachedProviderCredentialStore(upstream: upstream)

        try cache.saveAPIKey("sk-demo-002", for: "text.primary")
        let loaded = try cache.loadAPIKey(for: "text.primary")

        XCTAssertEqual(loaded, "sk-demo-002")
        XCTAssertEqual(upstream.loadCount, 0)
        XCTAssertEqual(upstream.saveCount, 1)
    }

    func testDeleteMarksCacheMissing() throws {
        let upstream = CountingCredentialStore()
        try upstream.saveAPIKey("sk-demo-003", for: "text.primary")
        let cache = CachedProviderCredentialStore(upstream: upstream)

        _ = try cache.loadAPIKey(for: "text.primary")
        try cache.deleteAPIKey(for: "text.primary")
        let loaded = try cache.loadAPIKey(for: "text.primary")

        XCTAssertNil(loaded)
        XCTAssertEqual(upstream.loadCount, 1)
        XCTAssertEqual(upstream.deleteCount, 1)
    }
}

private final class CountingCredentialStore: ProviderCredentialStore {
    private var storage: [String: String] = [:]
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    func loadAPIKey(for profileID: String) throws -> String? {
        loadCount += 1
        return storage[profileID]
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {
        saveCount += 1
        storage[profileID] = value
    }

    func deleteAPIKey(for profileID: String) throws {
        deleteCount += 1
        storage.removeValue(forKey: profileID)
    }

    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool {
        storage[profileID]?.isEmpty == false
    }
}

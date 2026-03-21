import Foundation

final class CachedProviderCredentialStore: ProviderCredentialStore {
    private let upstream: ProviderCredentialStore
    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()

    init(upstream: ProviderCredentialStore) {
        self.upstream = upstream
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        if let cached = cachedValue(for: profileID) {
            return cached
        }

        let loaded = try upstream.loadAPIKey(for: profileID)
        storeCache(loaded, for: profileID)
        return loaded
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {
        try upstream.saveAPIKey(value, for: profileID)
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        storeCache(normalized.isEmpty ? nil : normalized, for: profileID)
    }

    func deleteAPIKey(for profileID: String) throws {
        try upstream.deleteAPIKey(for: profileID)
        storeCache(nil, for: profileID)
    }

    private func cachedValue(for profileID: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[profileID] else {
            return nil
        }
        switch entry {
        case let .value(value):
            return .some(value)
        case .missing:
            return .some(nil)
        }
    }

    private func storeCache(_ value: String?, for profileID: String) {
        lock.lock()
        defer { lock.unlock() }
        cache[profileID] = value.map(CacheEntry.value) ?? .missing
    }
}

private extension CachedProviderCredentialStore {
    enum CacheEntry {
        case value(String)
        case missing
    }
}

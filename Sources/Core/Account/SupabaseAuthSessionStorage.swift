import Foundation
import Supabase

struct SupabaseAuthSessionStorage: AuthLocalStorage {
    private let storage: KeychainLocalStorage

    init(service: String = "com.niushuanan.PulseType.auth.v1") {
        storage = KeychainLocalStorage(service: service)
    }

    func store(key: String, value: Data) throws {
        try storage.store(key: key, value: value)
    }

    func retrieve(key: String) throws -> Data? {
        try storage.retrieve(key: key)
    }

    func remove(key: String) throws {
        try storage.remove(key: key)
    }
}

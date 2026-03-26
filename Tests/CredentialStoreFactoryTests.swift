import Foundation
import XCTest
@testable import PulseType

final class CredentialStoreFactoryTests: XCTestCase {
    func testFactoryCreatesFileBackedCredentialStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("credential-factory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = CredentialStoreFactory.makeProviderCredentialStore(credentialsDirectory: directory)
        try store.saveAPIKey(" sk-demo ", for: "asr.primary")

        let credentialsFile = directory.appendingPathComponent("credentials.v1.json")
        let data = try Data(contentsOf: credentialsFile)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let values = json?["values"] as? [String: String]

        XCTAssertEqual(try store.loadAPIKey(for: "asr.primary"), "sk-demo")
        XCTAssertEqual(values?["asr.primary"], "sk-demo")
    }
}

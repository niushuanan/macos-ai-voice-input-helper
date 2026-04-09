import Foundation
import XCTest
@testable import PulseType

final class V4ToolManifestTests: XCTestCase {
    func testManifestSearchByKeywordAndFeature() throws {
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v4-tool-manifest-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: historyDirectory) }

        let registry = V4ToolRegistry.live(
            timeMachineService: V4TimeMachineService(historyDirectory: historyDirectory)
        )

        let byAlias = registry.search(keyword: "mail.compose_or_send")
        XCTAssertTrue(byAlias.contains(where: { $0.toolID == "apple.mail.compose" }))

        let byChinese = registry.search(keyword: "日程")
        XCTAssertTrue(byChinese.contains(where: { $0.toolID == "apple.calendar.create" }))
        let byLocalMD = registry.search(keyword: "本地")
        XCTAssertTrue(byLocalMD.contains(where: { $0.toolID == "md.pipeline" }))

        let markdownTools = Set(registry.list(by: .markdownDocument).map(\.toolID))
        XCTAssertTrue(markdownTools.contains("md.pipeline"))
        XCTAssertTrue(markdownTools.contains("apple.notes.create"))

        let clockTools = Set(registry.list(by: .clock).map(\.toolID))
        XCTAssertTrue(clockTools.contains("time_machine.create"))
        XCTAssertTrue(clockTools.contains("time_machine.remind"))
    }

    func testManifestIncludesRetryAndEvidenceMetadata() {
        let registry = V4ToolRegistry.live()

        let mail = registry.search(keyword: "mail.compose_or_send").first { $0.toolID == "apple.mail.compose" }
        XCTAssertNotNil(mail)
        XCTAssertEqual(mail?.supportsRetry, true)
        XCTAssertEqual(mail?.evidenceRequirement.level, .structured)
        XCTAssertEqual(mail?.requiredFeature, .mail)

        let feishu = registry.search(keyword: "feishu.cli").first { $0.toolID == "feishu.cli" }
        XCTAssertNotNil(feishu)
        XCTAssertEqual(feishu?.requiredFeature, nil)
    }
}

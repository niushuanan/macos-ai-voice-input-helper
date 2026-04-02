import Foundation
import XCTest
@testable import PulseType

final class V4ToolManifestTests: XCTestCase {
    func testManifestSearchByKeywordAndScope() {
        let registry = V4ToolRegistry.live()

        let byAlias = registry.search(keyword: "mail.compose_or_send")
        XCTAssertTrue(byAlias.contains(where: { $0.toolID == "apple.mail.compose" }))

        let byChinese = registry.search(keyword: "日程")
        XCTAssertTrue(byChinese.contains(where: { $0.toolID == "apple.calendar.create" }))
        let byLocalMD = registry.search(keyword: "本地")
        XCTAssertTrue(byLocalMD.contains(where: { $0.toolID == "local.md.create" }))

        let appleTools = registry.list(by: .appleNativeApps)
        let toolIDs = Set(appleTools.map(\.toolID))
        XCTAssertTrue(toolIDs.contains("apple.calendar.create"))
        XCTAssertTrue(toolIDs.contains("apple.notes.create"))
        XCTAssertTrue(toolIDs.contains("apple.mail.compose"))
        XCTAssertTrue(toolIDs.contains("apple.music.control"))
    }

    func testManifestIncludesRetryAndEvidenceMetadata() {
        let registry = V4ToolRegistry.live()

        let feishu = registry.search(keyword: "feishu.cli").first { $0.toolID == "feishu.cli" }
        XCTAssertNotNil(feishu)
        XCTAssertEqual(feishu?.supportsRetry, true)
        XCTAssertEqual(feishu?.evidenceRequirement.level, .structured)
        XCTAssertEqual(feishu?.requiredScope, .feishu)
    }
}

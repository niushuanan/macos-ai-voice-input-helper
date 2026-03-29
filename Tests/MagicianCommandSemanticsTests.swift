import XCTest
@testable import PulseType

final class MagicianCommandSemanticsTests: XCTestCase {
    func testCLIArgumentsLookCompleteRejectsDanglingFlag() {
        XCTAssertFalse(magicianCLIArgumentsLookComplete(["--chat-id", "oc_123", "--text"]))
        XCTAssertFalse(magicianCLIArgumentsLookComplete(["--chat-id", "--text", "hi"]))
        XCTAssertTrue(magicianCLIArgumentsLookComplete(["--chat-id", "oc_123", "--text", "hi"]))
    }

    func testMagicianResolvedPayloadPrefersSelection() {
        let payload = magicianResolvedPayload(
            selectedText: "这是选中的正文",
            sourceText: "这是模型猜的正文",
            command: "帮我写进备忘录",
            actionTokens: ["备忘录", "写进备忘录"]
        )

        XCTAssertEqual(payload, "这是选中的正文")
    }

    func testMagicianSemanticPayloadStripsRecipientDirectiveForMail() {
        let payload = magicianSemanticPayload(
            from: "给小庄发邮件，告诉他我今天会晚点到",
            actionTokens: ["邮件", "发邮件"],
            stripRecipientDirectives: true
        )

        XCTAssertEqual(payload, "告诉他我今天会晚点到")
    }

    func testExtractMailRecipientHintsForChainedInstruction() {
        let hints = magicianExtractMailRecipientHints(
            from: "翻译成日语，并给不孤独发邮件"
        )

        XCTAssertEqual(hints, ["不孤独"])
    }

    func testExtractExplicitEmailsFromInstruction() {
        let emails = magicianExtractExplicitEmails(
            from: "请发邮件给 team@example.com 和 dev@example.com"
        )

        XCTAssertEqual(emails, ["team@example.com", "dev@example.com"])
    }
}

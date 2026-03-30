import XCTest
@testable import PulseType

final class FeishuResultVerifierTests: XCTestCase {
    private let verifier = FeishuResultVerifier()

    func testCalendarCreateRequiresEventID() {
        let result = verifier.verifySuccess(
            operation: .calendarEvent,
            plan: FeishuCLICommandPlan(
                executablePath: "/tmp/lark-cli",
                arguments: ["calendar", "+create", "--summary", "上课"],
                summary: "日程事件（lark-cli）",
                riskLevel: .write,
                executionMode: .execute
            ),
            output: #"{"ok":true,"identity":"user","data":{"summary":"上课"}}"#
        )

        switch result {
        case .verified:
            XCTFail("expected verification failure without event_id")
        case let .failed(userMessage, _):
            XCTAssertTrue(userMessage.contains("日程 ID"))
        }
    }

    func testMessageSendAcceptsMessageID() {
        let result = verifier.verifySuccess(
            operation: .imUserMessage,
            plan: FeishuCLICommandPlan(
                executablePath: "/tmp/lark-cli",
                arguments: ["im", "+messages-send", "--as", "bot"],
                summary: "发送消息（lark-cli）",
                riskLevel: .write,
                executionMode: .execute
            ),
            output: #"{"ok":true,"identity":"bot","data":{"message_id":"om_test_123"}}"#
        )

        switch result {
        case let .verified(observation):
            XCTAssertEqual(observation.verificationStatus, .verified)
            XCTAssertTrue(observation.evidenceSummary?.contains("om_test_123") == true)
        case let .failed(userMessage, _):
            XCTFail("expected success but got failure: \(userMessage)")
        }
    }

    func testBitableCreateRequiresAppTokenWhenCreatePathUsed() {
        let result = verifier.verifySuccess(
            operation: .bitableApp,
            plan: FeishuCLICommandPlan(
                executablePath: "/tmp/lark-cli",
                arguments: ["base", "+base-create", "--name", "测试表"],
                summary: "多维表格 App（lark-cli）",
                riskLevel: .write,
                executionMode: .execute
            ),
            output: #"{"ok":true,"identity":"user","data":{"name":"测试表"}}"#
        )

        switch result {
        case .verified:
            XCTFail("expected verification failure without app_token")
        case let .failed(userMessage, _):
            XCTAssertTrue(userMessage.contains("多维表格标识"))
        }
    }

    func testStructuredWriteWithoutEvidenceFails() {
        let result = verifier.verifySuccess(
            operation: .updateDoc,
            plan: FeishuCLICommandPlan(
                executablePath: "/tmp/lark-cli",
                arguments: ["docs", "+update", "--doc", "doccn123"],
                summary: "更新文档（lark-cli）",
                riskLevel: .write,
                executionMode: .execute
            ),
            output: #"{"ok":true,"identity":"user","data":{"status":"ok"}}"#
        )

        switch result {
        case .verified:
            XCTFail("expected verification failure without evidence id")
        case let .failed(userMessage, _):
            XCTAssertTrue(
                userMessage.contains("可核验")
                    || userMessage.contains("文档标识")
                    || userMessage.contains("无法确认")
            )
        }
    }
}

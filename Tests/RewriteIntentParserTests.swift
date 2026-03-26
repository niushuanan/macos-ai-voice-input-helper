import XCTest
@testable import PulseType

final class RewriteIntentParserTests: XCTestCase {
    private let parser = RewriteIntentParser()

    func testTranslateIntentDetectsJapanese() throws {
        let intent = try parser.parse(instruction: "请翻译成日语")

        switch intent.action {
        case let .translate(targetLanguage):
            XCTAssertEqual(targetLanguage, "Japanese")
        default:
            XCTFail("Expected translate action.")
        }
    }

    func testGenericPolishRespectsStructuredSceneBias() throws {
        let intent = try parser.parse(
            instruction: "润色一下",
            defaultOutputBias: .structured
        )

        switch intent.action {
        case .structure:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected structure action for structured scene bias.")
        }
    }

    func testStyleTransformationUsesCustomActionInsteadOfStructureHeuristic() throws {
        let intent = try parser.parse(instruction: "转换为中国古诗风格")

        switch intent.action {
        case let .custom(command):
            XCTAssertEqual(command, "转换为中国古诗风格")
            XCTAssertEqual(intent.action.label, "转换为中国古诗风格")
        default:
            XCTFail("Expected custom action for style transformation.")
        }
    }

    func testStyleTransformationContainingOrganizeStillUsesCustomAction() throws {
        let intent = try parser.parse(instruction: "请整理成中国古诗风格")

        switch intent.action {
        case let .custom(command):
            XCTAssertEqual(command, "请整理成中国古诗风格")
        default:
            XCTFail("Expected custom action instead of structure.")
        }
    }

    func testEmptyInstructionThrows() {
        XCTAssertThrowsError(try parser.parse(instruction: "   ")) { error in
            guard case RewriteProviderError.emptyInstruction = error else {
                XCTFail("Expected emptyInstruction error, got \(error)")
                return
            }
        }
    }
}

final class RewritePromptBuilderTests: XCTestCase {
    func testPromptTreatsSpokenInstructionAsHighestPriority() {
        let builder = MagicianTextTransformPromptBuilder()
        let template = builder.build(
            intent: RewriteIntent(
                action: .custom(command: "转换为中国古诗风格"),
                sourceInstruction: "转换为中国古诗风格"
            ),
            request: SelectionRewriteRequest(
                selectedText: "今天下午三点在会议室开产品评审会。",
                spokenInstruction: "转换为中国古诗风格",
                focusContext: FocusedAppContext(
                    appName: "TextEdit",
                    bundleID: "com.apple.TextEdit",
                    focusedRole: "AXTextArea",
                    hasEditableTarget: true,
                    strategyHint: "test"
                ),
                outputBias: .neutral,
                appPrompt: "尽量写成要点。",
                userSystemPrompt: "更简洁。"
            )
        )

        XCTAssertTrue(template.systemPrompt.contains("highest-priority instruction"))
        XCTAssertTrue(template.systemPrompt.contains("Do not summarize, reorder, structure into bullet points"))
        XCTAssertTrue(template.userPrompt.contains("转换为中国古诗风格"))
        XCTAssertFalse(template.userPrompt.contains("Action:"))
        XCTAssertFalse(template.systemPrompt.contains("尽量写成要点"))
        XCTAssertFalse(template.systemPrompt.contains("更简洁"))
        XCTAssertFalse(template.userPrompt.contains("尽量写成要点"))
        XCTAssertFalse(template.userPrompt.contains("更简洁"))
    }

    func testPromptUsesDedicatedMagicianProfileInsteadOfExternalPreferences() {
        let builder = MagicianTextTransformPromptBuilder()
        let template = builder.build(
            intent: RewriteIntent(
                action: .custom(command: "改成更正式但保留原意"),
                sourceInstruction: "改成更正式但保留原意"
            ),
            request: SelectionRewriteRequest(
                selectedText: "明天下午三点，我们在 A 会议室过一下方案。",
                spokenInstruction: "改成更正式但保留原意",
                focusContext: FocusedAppContext(
                    appName: "WeChat",
                    bundleID: "com.tencent.xinWeChat",
                    focusedRole: nil,
                    hasEditableTarget: false,
                    strategyHint: "copy-fallback"
                ),
                outputBias: .neutral,
                appPrompt: "请优先输出清晰结论。",
                userSystemPrompt: "更简洁。"
            )
        )

        XCTAssertTrue(template.systemPrompt.contains("PulseType"))
        XCTAssertTrue(template.systemPrompt.contains("Selected text and the spoken command are separate channels"))
        XCTAssertTrue(template.userPrompt.contains("改成更正式但保留原意"))
        XCTAssertTrue(template.userPrompt.contains("明天下午三点，我们在 A 会议室过一下方案。"))
        XCTAssertFalse(template.systemPrompt.contains("App-specific instruction"))
        XCTAssertFalse(template.systemPrompt.contains("User preference system instruction"))
    }
}

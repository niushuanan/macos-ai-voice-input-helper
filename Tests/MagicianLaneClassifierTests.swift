import XCTest
@testable import PulseType

final class MagicianLaneClassifierTests: XCTestCase {
    private let classifier = MagicianLaneClassifier()

    func testPureTextGoesNativeFast() {
        let decision = classifier.decide(
            command: "帮我把这段话改得更正式一点",
            selectionSnapshot: nil,
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .nativeFast)
    }

    func testTextPlusMailGoesNativeFast() {
        let decision = classifier.decide(
            command: "把这段话整理一下，再发邮件给产品组",
            selectionSnapshot: selection("当前这段文字"),
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .nativeFast)
    }

    func testTextPlusNotesGoesNativeFast() {
        let decision = classifier.decide(
            command: "把这段话整理成三点，再写进备忘录",
            selectionSnapshot: selection("当前这段文字"),
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .nativeFast)
    }

    func testTextPlusCalendarGoesNativeFast() {
        let decision = classifier.decide(
            command: "把这段话整理成会议摘要，再创建日程",
            selectionSnapshot: selection("4月1日 14:30 产品评审"),
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .nativeFast)
    }

    func testSingleStepMusicGoesNativeFast() {
        let decision = classifier.decide(
            command: "播放周杰伦的稻香",
            selectionSnapshot: nil,
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .nativeFast)
    }

    func testTextPlusFeishuGoesAgent() {
        let decision = classifier.decide(
            command: "把这段话翻译成英文，然后发到飞书群",
            selectionSnapshot: selection("需要翻译的内容"),
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .agent)
    }

    func testMailPlusFeishuIsRejected() {
        let decision = classifier.decide(
            command: "发邮件给产品组并同步到飞书",
            selectionSnapshot: nil,
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .unsupportedMixedExternal)
        XCTAssertTrue(decision.userMessage?.contains("拆开说") == true)
    }

    func testNotesPlusFeishuIsRejected() {
        let decision = classifier.decide(
            command: "写进备忘录并发到飞书",
            selectionSnapshot: nil,
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .unsupportedMixedExternal)
    }

    func testCalendarPlusFeishuIsRejected() {
        let decision = classifier.decide(
            command: "创建日程并同步到飞书",
            selectionSnapshot: nil,
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .unsupportedMixedExternal)
    }

    private func selection(_ text: String) -> FocusedSelectionSnapshot {
        FocusedSelectionSnapshot(
            focusContext: FocusedAppContext(
                appName: "TextEdit",
                bundleID: "com.apple.TextEdit",
                focusedRole: "AXTextArea",
                hasEditableTarget: true,
                strategyHint: "test"
            ),
            selectedText: text
        )
    }
}

import XCTest
@testable import PulseType

final class TranscriptLedgerTests: XCTestCase {
    func testCompletedItemsStayOrderedWhileTentativeTailGrows() {
        var ledger = TranscriptLedger()

        ledger.apply(.delta(itemID: "item-a", confirmedText: "第一", tentativeText: ""))
        ledger.apply(.completed(itemID: "item-a", transcript: "第一句。"))
        ledger.apply(.delta(itemID: "item-b", confirmedText: "第二", tentativeText: ""))

        XCTAssertEqual(ledger.snapshot.committedText, "第一句。")
        XCTAssertEqual(ledger.snapshot.tentativeText, "第二")
        XCTAssertEqual(ledger.snapshot.previewText, "第一句。第二")

        ledger.apply(.delta(itemID: "item-b", confirmedText: "第二", tentativeText: "句"))

        XCTAssertEqual(ledger.snapshot.previewText, "第一句。第二句")
    }

    func testCompletedTranscriptReplacesAccumulatedDeltasWithoutDuplication() {
        var ledger = TranscriptLedger()

        ledger.apply(.delta(itemID: "item-a", confirmedText: "你好", tentativeText: "世"))
        ledger.apply(.delta(itemID: "item-a", confirmedText: "你好", tentativeText: "世界"))
        ledger.apply(.completed(itemID: "item-a", transcript: "你好，世界。"))

        XCTAssertEqual(ledger.snapshot.committedText, "你好，世界。")
        XCTAssertEqual(ledger.snapshot.tentativeText, "")
        XCTAssertEqual(ledger.snapshot.finalText, "你好，世界。")
    }

    func testLateDeltaCannotMutateCompletedItem() {
        var ledger = TranscriptLedger()

        ledger.apply(.completed(itemID: "item-a", transcript: "最终文本。"))
        ledger.apply(.delta(itemID: "item-a", confirmedText: "过期", tentativeText: "片段"))

        XCTAssertEqual(ledger.snapshot.finalText, "最终文本。")
    }

    func testRepeatedCompletedEventUpdatesAuthorityWithoutChangingItemOrder() {
        var ledger = TranscriptLedger()

        ledger.apply(.completed(itemID: "item-a", transcript: "第一句"))
        ledger.apply(.completed(itemID: "item-b", transcript: "第二句"))
        ledger.apply(.completed(itemID: "item-a", transcript: "第一句。"))

        XCTAssertEqual(ledger.snapshot.finalText, "第一句。第二句")
    }

    func testEnglishItemsReceiveBoundarySpaceButChineseItemsDoNot() {
        var english = TranscriptLedger()
        english.apply(.completed(itemID: "item-a", transcript: "hello"))
        english.apply(.completed(itemID: "item-b", transcript: "world"))

        var chinese = TranscriptLedger()
        chinese.apply(.completed(itemID: "item-a", transcript: "你好"))
        chinese.apply(.completed(itemID: "item-b", transcript: "世界"))

        XCTAssertEqual(english.snapshot.finalText, "hello world")
        XCTAssertEqual(chinese.snapshot.finalText, "你好世界")
    }

    func testTentativeStashCanBeRevisedWithoutDuplicatingConfirmedPrefix() {
        var ledger = TranscriptLedger()

        ledger.apply(.delta(itemID: "item-a", confirmedText: "今天", tentativeText: "下雨"))
        XCTAssertEqual(ledger.snapshot.previewText, "今天下雨")

        ledger.apply(.delta(itemID: "item-a", confirmedText: "今天", tentativeText: "天气"))
        XCTAssertEqual(ledger.snapshot.previewText, "今天天气")

        ledger.apply(.delta(itemID: "item-a", confirmedText: "今天天气", tentativeText: "很好"))
        XCTAssertEqual(ledger.snapshot.previewText, "今天天气很好")
    }
}

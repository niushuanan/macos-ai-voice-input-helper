import XCTest
@testable import PulseType

final class V4TimeParserTests: XCTestCase {
    func testParseRelativeTimeExpression() {
        let parser = makeParser()
        let referenceDate = makeDate(year: 2026, month: 4, day: 2, hour: 10, minute: 0)

        let result = parser.parse(
            "30 分钟后提醒我给客户回电话",
            referenceDate: referenceDate
        )

        XCTAssertEqual(result.status, .parsed)
        XCTAssertEqual(result.kind, .relative)
        XCTAssertEqual(result.scheduledAt, makeDate(year: 2026, month: 4, day: 2, hour: 10, minute: 30))
        XCTAssertEqual(result.normalizedText, "给客户回电话")
    }

    func testParseAbsoluteTimeExpression() {
        let parser = makeParser()
        let referenceDate = makeDate(year: 2026, month: 4, day: 2, hour: 10, minute: 0)

        let result = parser.parse(
            "今晚 8 点提醒我交方案",
            referenceDate: referenceDate
        )

        XCTAssertEqual(result.status, .parsed)
        XCTAssertEqual(result.kind, .absolute)
        XCTAssertEqual(result.scheduledAt, makeDate(year: 2026, month: 4, day: 2, hour: 20, minute: 0))
        XCTAssertEqual(result.normalizedText, "交方案")
    }

    func testParseFailureReturnsStructuredHint() {
        let parser = makeParser()
        let referenceDate = makeDate(year: 2026, month: 4, day: 2, hour: 10, minute: 0)

        let result = parser.parse(
            "提醒我找个合适的时候交方案",
            referenceDate: referenceDate
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.hint?.code, "time_not_understood")
        XCTAssertTrue(result.hint?.supportedExamples.contains("今晚 8 点") == true)
        XCTAssertTrue(result.hint?.userMessage.contains("没听懂提醒时间") == true)
    }

    private func makeParser() -> V4TimeParser {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return V4TimeParser(calendar: calendar)
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        return calendar.date(from: components)!
    }
}

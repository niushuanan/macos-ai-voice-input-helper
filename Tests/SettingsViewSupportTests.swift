import XCTest
@testable import PulseType

final class SettingsViewSupportTests: XCTestCase {
    func testMemoryToolbarUsesSingleRowWhenThereIsEnoughSpace() {
        let mode = MemoryToolbarLayoutMode.resolve(
            availableWidth: 560,
            filterBarWidth: 320,
            clearButtonWidth: 140,
            spacing: 12
        )

        XCTAssertEqual(mode, .singleRow)
    }

    func testMemoryToolbarFallsBackToStackedWhenSpaceIsTight() {
        let mode = MemoryToolbarLayoutMode.resolve(
            availableWidth: 420,
            filterBarWidth: 320,
            clearButtonWidth: 140,
            spacing: 12
        )

        XCTAssertEqual(mode, .stacked)
    }

    func testMemoryToolbarDefaultsToSingleRowBeforeWidthIsMeasured() {
        let mode = MemoryToolbarLayoutMode.resolve(
            availableWidth: 0,
            filterBarWidth: 280,
            clearButtonWidth: 132,
            spacing: 12
        )

        XCTAssertEqual(mode, .singleRow)
    }

    func testConnectionFailureAdvisorHandlesAuthFailure() {
        let result = ConnectionTestResult(
            status: .failure,
            message: "请求失败",
            hint: "请检查配置",
            timestamp: Date(timeIntervalSince1970: 1_711_000_100),
            httpStatus: 401
        )

        XCTAssertEqual(
            ConnectionFailureAdvisor.suggestion(for: result),
            "请核对 API Key 是否正确、是否过期，并确认模型权限。"
        )
    }

    func testConnectionFailureAdvisorHandlesModelNameFailureWithoutHTTPCode() {
        let result = ConnectionTestResult(
            status: .failure,
            message: "模型不可用",
            hint: "模型名不存在",
            timestamp: Date(timeIntervalSince1970: 1_711_000_200),
            httpStatus: nil
        )

        XCTAssertEqual(
            ConnectionFailureAdvisor.suggestion(for: result),
            "请确认模型名与服务端可用模型一致。"
        )
    }

    func testConnectionFailureAdvisorReturnsGenericChecklistWhenSignalsAreWeak() {
        let result = ConnectionTestResult(
            status: .failure,
            message: "连接异常",
            hint: "稍后重试",
            timestamp: Date(timeIntervalSince1970: 1_711_000_300),
            httpStatus: nil
        )

        XCTAssertEqual(
            ConnectionFailureAdvisor.suggestion(for: result),
            "建议依次检查地址、模型名、密钥、额度和网络。"
        )
    }
}

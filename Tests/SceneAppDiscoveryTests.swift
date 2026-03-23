import AppKit
import XCTest
@testable import PulseType

final class SceneAppDiscoveryTests: XCTestCase {
    func testRunningRegularCandidateOverridesInstalledCandidate() {
        var map: [String: SceneAppOption] = [:]

        SceneAppDiscovery.upsertCandidate(
            appName: "微信",
            bundleID: "com.tencent.xinWeChat",
            source: .installed,
            selfBundleID: nil,
            map: &map
        )
        SceneAppDiscovery.upsertCandidate(
            appName: "微信（运行中）",
            bundleID: "com.tencent.xinWeChat",
            source: .running(activationPolicy: .regular),
            selfBundleID: nil,
            map: &map
        )

        XCTAssertEqual(map["com.tencent.xinWeChat"]?.sourcePriority, .runningRegular)
        XCTAssertEqual(map["com.tencent.xinWeChat"]?.appName, "微信（运行中）")
    }

    func testRunningInputMethodAccessoryCandidateIsKept() {
        var map: [String: SceneAppOption] = [:]

        SceneAppDiscovery.upsertCandidate(
            appName: "微信输入法",
            bundleID: "com.tencent.inputmethod.wetype",
            source: .running(activationPolicy: .accessory),
            selfBundleID: nil,
            map: &map
        )

        XCTAssertEqual(map["com.tencent.inputmethod.wetype"]?.sourcePriority, .runningInputMethod)
    }

    func testRunningAccessoryCandidateWithoutInputMethodIsDropped() {
        var map: [String: SceneAppOption] = [:]

        SceneAppDiscovery.upsertCandidate(
            appName: "微信",
            bundleID: "com.tencent.xinWeChat.WeChatAppEx",
            source: .running(activationPolicy: .accessory),
            selfBundleID: nil,
            map: &map
        )

        XCTAssertNil(map["com.tencent.xinWeChat.WeChatAppEx"])
    }

    func testHelperKeywordCandidateIsDropped() {
        var map: [String: SceneAppOption] = [:]

        SceneAppDiscovery.upsertCandidate(
            appName: "WeChat Helper",
            bundleID: "com.tencent.xinWeChat.WeChatAppEx.helper.renderer",
            source: .installed,
            selfBundleID: nil,
            map: &map
        )

        XCTAssertTrue(map.isEmpty)
    }

    func testCurrentAppBundleIDIsDropped() {
        var map: [String: SceneAppOption] = [:]

        SceneAppDiscovery.upsertCandidate(
            appName: "PulseType",
            bundleID: "com.niushuanan.PulseType",
            source: .running(activationPolicy: .regular),
            selfBundleID: "com.niushuanan.PulseType",
            map: &map
        )

        XCTAssertTrue(map.isEmpty)
    }
}

import Foundation
import XCTest
@testable import PulseType

final class AppRuntimePolicyTests: XCTestCase {
    func testAllowsAlternateRuntimeForTestsOrDebugOverride() {
        XCTAssertTrue(
            AppRuntimePolicy.fallback.allowsAlternateRuntime(
                environment: [:],
                isRunningUnderTests: true
            )
        )
        XCTAssertTrue(
            AppRuntimePolicy.fallback.allowsAlternateRuntime(
                environment: [AppRuntimePolicy.fallback.debugRuntimeEnvironmentKey: "1"],
                isRunningUnderTests: false
            )
        )
        XCTAssertFalse(
            AppRuntimePolicy.fallback.allowsAlternateRuntime(
                environment: [:],
                isRunningUnderTests: false
            )
        )
    }

    func testLoadReadsPolicyFromPlistURL() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-policy-\(UUID().uuidString)")
            .appendingPathExtension("plist")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>appName</key>
            <string>PulseType QA</string>
            <key>bundleIdentifier</key>
            <string>com.niushuanan.PulseType.qa</string>
            <key>debugRuntimeEnvironmentKey</key>
            <string>PULSETYPE_ALLOW_ALT_RUNTIME</string>
            <key>installPath</key>
            <string>/Applications/PulseType-QA.app</string>
            <key>launchServicesToolPath</key>
            <string>/usr/bin/true</string>
        </dict>
        </plist>
        """
        try plist.write(to: fileURL, atomically: true, encoding: .utf8)

        let policy = try AppRuntimePolicy.load(from: fileURL)

        XCTAssertEqual(policy.appName, "PulseType QA")
        XCTAssertEqual(policy.bundleIdentifier, "com.niushuanan.PulseType.qa")
        XCTAssertEqual(policy.installPath, "/Applications/PulseType-QA.app")
        XCTAssertEqual(policy.debugRuntimeEnvironmentKey, "PULSETYPE_ALLOW_ALT_RUNTIME")
        XCTAssertEqual(policy.launchServicesToolPath, "/usr/bin/true")
    }
}

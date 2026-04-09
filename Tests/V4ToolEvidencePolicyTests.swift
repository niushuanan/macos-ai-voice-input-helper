import XCTest
@testable import PulseType

final class V4ToolEvidencePolicyTests: XCTestCase {
    func testStructuredEvidenceAllowsSummaryFallbackWhenRawPayloadMissing() {
        let spec = V4ToolSpec(
            toolName: "apple.music.control",
            displayName: "控制音乐",
            summary: "控制音乐",
            supportedLanes: V4Lane.allCases,
            inputSchemaVersion: "v1",
            inputSchema: V4ToolInputSchema(fields: []),
            requiresPermission: false,
            requiredFeature: nil,
            isConcurrencySafe: true,
            mutatesUserData: false,
            supportsStreamingResults: false
        )
        let manifest = V4ToolManifest.derived(
            from: spec,
            evidenceRequirement: .structured(requiredKeys: ["action", "state"])
        )
        let output = V4ToolExecutionOutput(
            outputText: "已开始播放",
            evidenceSummary: "apple.music.control action=play state=play",
            rawPayload: nil
        )

        let error = V4ToolEvidencePolicy().validate(
            output: output,
            manifest: manifest,
            toolID: "apple.music.control",
            errorCatalog: V4ToolErrorCatalog()
        )

        XCTAssertNil(error)
    }

    func testStructuredEvidenceStillFailsWhenRequiredKeyMissingEverywhere() {
        let spec = V4ToolSpec(
            toolName: "apple.music.control",
            displayName: "控制音乐",
            summary: "控制音乐",
            supportedLanes: V4Lane.allCases,
            inputSchemaVersion: "v1",
            inputSchema: V4ToolInputSchema(fields: []),
            requiresPermission: false,
            requiredFeature: nil,
            isConcurrencySafe: true,
            mutatesUserData: false,
            supportsStreamingResults: false
        )
        let manifest = V4ToolManifest.derived(
            from: spec,
            evidenceRequirement: .structured(requiredKeys: ["action", "state"])
        )
        let output = V4ToolExecutionOutput(
            outputText: "已开始播放",
            evidenceSummary: "apple.music.control action=play",
            rawPayload: nil
        )

        let error = V4ToolEvidencePolicy().validate(
            output: output,
            manifest: manifest,
            toolID: "apple.music.control",
            errorCatalog: V4ToolErrorCatalog()
        )

        XCTAssertEqual(error?.code, .verificationFailed)
    }
}

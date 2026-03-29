import XCTest
@testable import PulseType

final class FeishuCLIProviderTests: XCTestCase {
    func testInferCalendarEventFromNaturalChineseSentence() {
        let operation = FeishuCanonicalOperation.infer(
            from: "飞书，今天下午三点添加一个上课的日程。"
        )
        XCTAssertEqual(operation, .calendarEvent)
    }

    func testExecuteOAuthUsesStatusWithoutFormatFlag() async throws {
        let fixture = try makeExecutableFixture(
            fileName: "lark-cli",
            script: "#!/bin/sh\necho \"$@\"\nexit 0\n"
        )
        defer { fixture.cleanUp() }

        let provider = FeishuCLIProvider()
        let availability = FeishuCLIAvailability(
            backend: FeishuCLIBackendDescriptor(
                kind: .larkCLI,
                executablePath: fixture.executableURL.path,
                commandName: "lark-cli"
            )
        )

        let result = await provider.execute(
            operation: .oauth,
            spokenCommand: "检查飞书授权状态",
            explicitArguments: [],
            availability: availability
        )

        switch result {
        case let .success(success):
            XCTAssertEqual(success.intent, .feishuCLI)
            XCTAssertTrue((success.outputText ?? "").contains("auth status"))
            XCTAssertFalse((success.outputText ?? "").contains("--format"))
        case let .failure(error):
            XCTFail("expected success but got error: \(error)")
        }
    }

    func testExecuteOAuthBatchAuthUsesNoWaitLogin() async throws {
        let fixture = try makeExecutableFixture(
            fileName: "lark-cli",
            script: "#!/bin/sh\necho \"$@\"\nexit 0\n"
        )
        defer { fixture.cleanUp() }

        let provider = FeishuCLIProvider()
        let availability = FeishuCLIAvailability(
            backend: FeishuCLIBackendDescriptor(
                kind: .larkCLI,
                executablePath: fixture.executableURL.path,
                commandName: "lark-cli"
            )
        )

        let result = await provider.execute(
            operation: .oauthBatchAuth,
            spokenCommand: "飞书批量授权",
            explicitArguments: [],
            availability: availability
        )

        switch result {
        case let .success(success):
            XCTAssertTrue((success.outputText ?? "").contains("auth login --recommend --no-wait"))
        case let .failure(error):
            XCTFail("expected success but got error: \(error)")
        }
    }

    func testExecuteReturnsFailureWhenHelpFallbackIsUsedWithoutDetails() async throws {
        let fixture = try makeExecutableFixture(
            fileName: "lark-cli",
            script: "#!/bin/sh\necho \"usage help\"\nexit 0\n"
        )
        defer { fixture.cleanUp() }

        let provider = FeishuCLIProvider()
        let availability = FeishuCLIAvailability(
            backend: FeishuCLIBackendDescriptor(
                kind: .larkCLI,
                executablePath: fixture.executableURL.path,
                commandName: "lark-cli"
            )
        )

        let result = await provider.execute(
            operation: .createDoc,
            spokenCommand: "飞书创建文档",
            explicitArguments: [],
            availability: availability
        )

        switch result {
        case .success:
            XCTFail("expected failure but got success")
        case let .failure(error):
            XCTAssertEqual(error.code, .intentParseFailed)
            XCTAssertTrue(error.userMessage.contains("缺少必要参数"))
        }
    }

    func testCalendarEventNaturalLanguageBuildsCreateArgumentsWithoutHelp() async throws {
        let fixture = try makeExecutableFixture(
            fileName: "lark-cli",
            script: "#!/bin/sh\necho \"$@\"\nexit 0\n"
        )
        defer { fixture.cleanUp() }

        let provider = FeishuCLIProvider()
        let availability = FeishuCLIAvailability(
            backend: FeishuCLIBackendDescriptor(
                kind: .larkCLI,
                executablePath: fixture.executableURL.path,
                commandName: "lark-cli"
            )
        )

        let result = await provider.execute(
            operation: .calendarEvent,
            spokenCommand: "飞书，今天下午三点添加一个上课的日程。",
            explicitArguments: [],
            availability: availability
        )

        switch result {
        case let .success(success):
            let output = success.outputText ?? ""
            XCTAssertTrue(output.contains("calendar +create"))
            XCTAssertTrue(output.contains("--summary"))
            XCTAssertTrue(output.contains("上课"))
            XCTAssertTrue(output.contains("--start"))
            XCTAssertTrue(output.contains("--end"))
            XCTAssertFalse(output.contains("--help"))
        case let .failure(error):
            XCTFail("expected success but got error: \(error)")
        }
    }

    func testCalendarCreateFailsWhenEventIDMissingInSuccessEnvelope() async throws {
        let fixture = try makeExecutableFixture(
            fileName: "lark-cli",
            script: """
#!/bin/sh
echo '{"ok":true,"identity":"user","data":{"summary":"上课"}}'
exit 0
"""
        )
        defer { fixture.cleanUp() }

        let provider = FeishuCLIProvider()
        let availability = FeishuCLIAvailability(
            backend: FeishuCLIBackendDescriptor(
                kind: .larkCLI,
                executablePath: fixture.executableURL.path,
                commandName: "lark-cli"
            )
        )

        let result = await provider.execute(
            operation: .calendarEvent,
            spokenCommand: "飞书，今天下午三点添加一个上课的日程。",
            explicitArguments: [],
            availability: availability
        )

        switch result {
        case .success:
            XCTFail("expected failure when event_id missing")
        case let .failure(error):
            XCTAssertEqual(error.code, .toolExecutionFailed)
            XCTAssertTrue(error.userMessage.contains("日程 ID"))
        }
    }

    func testExecuteTransformsJSONFailureEnvelopeIntoUserFacingError() async throws {
        let fixture = try makeExecutableFixture(
            fileName: "lark-cli",
            script: """
#!/bin/sh
echo '{"ok":false,"identity":"bot","error":{"message":"Bot/User can NOT be out of the chat."}}'
exit 0
"""
        )
        defer { fixture.cleanUp() }

        let provider = FeishuCLIProvider()
        let availability = FeishuCLIAvailability(
            backend: FeishuCLIBackendDescriptor(
                kind: .larkCLI,
                executablePath: fixture.executableURL.path,
                commandName: "lark-cli"
            )
        )

        let result = await provider.execute(
            operation: .imUserMessage,
            spokenCommand: "给飞书助手发消息，告诉他我正在用 PulseType",
            explicitArguments: ["--chat-id", "oc_xxx", "--text", "hi"],
            availability: availability
        )

        switch result {
        case .success:
            XCTFail("expected failure but got success")
        case let .failure(error):
            XCTAssertEqual(error.code, .toolExecutionFailed)
            XCTAssertTrue(error.userMessage.contains("机器人当前不在目标群里"))
        }
    }

    func testIMUserMessageCanAutoResolveRecipientAndSend() async throws {
        let fixture = try makeExecutableFixture(
            fileName: "lark-cli",
            script: """
#!/bin/sh
if [ "$1" = "im" ] && [ "$2" = "+chat-search" ]; then
  echo '{"ok":true,"identity":"user","data":{"chats":[{"chat_id":"oc_123abc"}]}}'
  exit 0
fi
if [ "$1" = "im" ] && [ "$2" = "+messages-send" ]; then
  echo "$@"
  exit 0
fi
echo "$@"
exit 0
"""
        )
        defer { fixture.cleanUp() }

        let provider = FeishuCLIProvider()
        let availability = FeishuCLIAvailability(
            backend: FeishuCLIBackendDescriptor(
                kind: .larkCLI,
                executablePath: fixture.executableURL.path,
                commandName: "lark-cli"
            )
        )

        let result = await provider.execute(
            operation: .imUserMessage,
            spokenCommand: "给测试群发消息，告诉他我正在用 PulseType",
            explicitArguments: [],
            availability: availability
        )

        switch result {
        case let .success(success):
            let output = success.outputText ?? ""
            XCTAssertTrue(output.contains("+messages-send"))
            XCTAssertTrue(output.contains("--as bot"))
            XCTAssertTrue(output.contains("--chat-id oc_123abc"))
            XCTAssertTrue(output.contains("--text 我正在用 PulseType"))
        case let .failure(error):
            XCTFail("expected success but got error: \(error)")
        }
    }

    func testBuildProcessEnvironmentAddsExecutableDirectoryAndFallbackPath() {
        let environment = FeishuCLIProvider.buildProcessEnvironment(
            executablePath: "/tmp/custom-bin/lark-cli",
            environment: [
                "PATH": "/usr/bin:/bin",
                "HOME": "/tmp/demo-home"
            ]
        )
        let path = environment["PATH"] ?? ""
        XCTAssertTrue(path.contains("/tmp/custom-bin"))
        XCTAssertTrue(path.contains("/usr/local/bin"))
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertEqual(environment["HOME"], "/tmp/demo-home")
    }

    func testDetectAvailabilityUsesExplicitExecutableOverride() throws {
        let fixture = try makeExecutableFixture(fileName: "lark-cli")
        defer { fixture.cleanUp() }

        let availability = FeishuCLIProvider.detectAvailability(
            environment: ["PATH": ""],
            executableOverride: fixture.executableURL.path
        )

        XCTAssertEqual(availability.commandName, "lark-cli")
        XCTAssertEqual(availability.backend?.kind, .larkCLI)
        XCTAssertEqual(availability.backend?.executablePath, fixture.executableURL.path)
    }

    func testDetectAvailabilityResolvesDirectoryOverride() throws {
        let fixture = try makeExecutableFixture(fileName: "feishu")
        defer { fixture.cleanUp() }

        let availability = FeishuCLIProvider.detectAvailability(
            environment: ["PATH": ""],
            executableOverride: fixture.directoryURL.path
        )

        XCTAssertEqual(availability.commandName, "feishu")
        XCTAssertEqual(availability.backend?.kind, .feishu)
        XCTAssertEqual(availability.backend?.executablePath, fixture.executableURL.path)
    }

    func testDetectAvailabilityPrefersLarkCLIWhenBothExistInPath() throws {
        let fixture = try makeDualExecutableFixture()
        defer { fixture.cleanUp() }

        let availability = FeishuCLIProvider.detectAvailability(
            environment: ["PATH": fixture.directoryURL.path]
        )

        XCTAssertEqual(availability.commandName, "lark-cli")
        XCTAssertEqual(availability.backend?.kind, .larkCLI)
        XCTAssertEqual(availability.backend?.executablePath, fixture.larkCLIURL.path)
    }

    func testDetectAvailabilitySearchesAdditionalDirectories() throws {
        let fixture = try makeExecutableFixture(fileName: "lark-cli")
        defer { fixture.cleanUp() }

        let availability = FeishuCLIProvider.detectAvailability(
            environment: ["PATH": ""],
            executableOverride: nil,
            additionalSearchDirectories: [fixture.directoryURL.path]
        )

        XCTAssertEqual(availability.commandName, "lark-cli")
        XCTAssertEqual(availability.backend?.executablePath, fixture.executableURL.path)
    }

    private func makeExecutableFixture(
        fileName: String,
        script: String = "#!/bin/sh\nexit 0\n"
    ) throws -> ExecutableFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feishu-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let executableURL = directoryURL.appendingPathComponent(fileName)
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableURL.path
        )

        return ExecutableFixture(
            directoryURL: directoryURL,
            executableURL: executableURL,
            cleanUp: {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        )
    }

    private func makeDualExecutableFixture() throws -> DualExecutableFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feishu-cli-tests-dual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let larkCLIURL = directoryURL.appendingPathComponent("lark-cli")
        let feishuURL = directoryURL.appendingPathComponent("feishu")
        try "#!/bin/sh\nexit 0\n".write(to: larkCLIURL, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: feishuURL, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: larkCLIURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: feishuURL.path
        )

        return DualExecutableFixture(
            directoryURL: directoryURL,
            larkCLIURL: larkCLIURL,
            feishuURL: feishuURL,
            cleanUp: {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        )
    }
}

private struct ExecutableFixture {
    let directoryURL: URL
    let executableURL: URL
    let cleanUp: () -> Void
}

private struct DualExecutableFixture {
    let directoryURL: URL
    let larkCLIURL: URL
    let feishuURL: URL
    let cleanUp: () -> Void
}

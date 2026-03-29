import XCTest
@testable import PulseType

final class FeishuCLIProviderTests: XCTestCase {
    private struct InferCase {
        let operation: FeishuCanonicalOperation
        let command: String
    }

    private struct RouteCase {
        let operation: FeishuCanonicalOperation
        let command: String
        let explicitArguments: [String]
        let expectedTokens: [String]
    }

    private let fullNaturalLanguageInferCases: [InferCase] = [
        InferCase(operation: .bitableApp, command: "飞书打开多维表格 app"),
        InferCase(operation: .bitableAppTable, command: "飞书查看数据表 table list"),
        InferCase(operation: .bitableAppTableField, command: "飞书查看字段配置"),
        InferCase(operation: .bitableAppTableRecord, command: "飞书查看记录列表"),
        InferCase(operation: .bitableAppTableView, command: "飞书查看视图 table view"),
        InferCase(operation: .calendarCalendar, command: "飞书查看日历"),
        InferCase(operation: .calendarEvent, command: "飞书今天下午三点添加一个上课日程"),
        InferCase(operation: .calendarEventAttendee, command: "飞书邀请参会人 attendee"),
        InferCase(operation: .calendarFreebusy, command: "飞书查忙闲 freebusy"),
        InferCase(operation: .chat, command: "飞书搜索群聊 chat"),
        InferCase(operation: .chatMembers, command: "飞书查看群成员"),
        InferCase(operation: .createDoc, command: "飞书创建文档"),
        InferCase(operation: .docComments, command: "飞书添加评论"),
        InferCase(operation: .docMedia, command: "飞书文档图片 media 插入"),
        InferCase(operation: .driveFile, command: "飞书上传文件到云盘 drive file"),
        InferCase(operation: .fetchDoc, command: "飞书读取文档"),
        InferCase(operation: .getUser, command: "飞书获取用户信息"),
        InferCase(operation: .imBotImage, command: "飞书发图片 bot image"),
        InferCase(operation: .imUserFetchResource, command: "飞书下载消息资源"),
        InferCase(operation: .imUserGetMessages, command: "飞书查看消息列表"),
        InferCase(operation: .imUserGetThreadMessages, command: "飞书查看线程消息"),
        InferCase(operation: .imUserMessage, command: "飞书发送消息给同事"),
        InferCase(operation: .imUserSearchMessages, command: "飞书搜索消息"),
        InferCase(operation: .oauth, command: "飞书 oauth 授权状态"),
        InferCase(operation: .oauthBatchAuth, command: "飞书批量授权"),
        InferCase(operation: .searchDocWiki, command: "飞书搜文档 search wiki"),
        InferCase(operation: .searchUser, command: "飞书查人 search user"),
        InferCase(operation: .sheet, command: "飞书表格 sheet 读取"),
        InferCase(operation: .taskComment, command: "飞书任务评论"),
        InferCase(operation: .taskSubtask, command: "飞书创建子任务"),
        InferCase(operation: .taskTask, command: "飞书管理任务 task"),
        InferCase(operation: .taskTasklist, command: "飞书创建任务列表 tasklist"),
        InferCase(operation: .updateDoc, command: "飞书更新文档"),
        InferCase(operation: .wikiSpace, command: "飞书 wiki space"),
        InferCase(operation: .wikiSpaceNode, command: "飞书 wiki 节点")
    ]

    func testInferResolvesAllCanonicalOperationIDs() {
        for operation in FeishuCanonicalOperation.allCases {
            let inferred = FeishuCanonicalOperation.infer(from: operation.rawValue)
            XCTAssertEqual(
                inferred,
                operation,
                "Failed to infer operation id: \(operation.rawValue)"
            )
        }
    }

    func testInferNaturalLanguageCoverageForAll35Operations() {
        XCTAssertEqual(
            fullNaturalLanguageInferCases.count,
            FeishuCanonicalOperation.allCases.count
        )

        for item in fullNaturalLanguageInferCases {
            let inferred = FeishuCanonicalOperation.infer(from: item.command)
            XCTAssertEqual(
                inferred,
                item.operation,
                "command=\(item.command)"
            )
        }
    }

    func testInferSupportsMixedLanguageAndPunctuationVariants() {
        let variants: [InferCase] = [
            InferCase(operation: .calendarEvent, command: "Feishu, add a class event at 3pm today."),
            InferCase(operation: .imUserMessage, command: "飞书：message send 给团队"),
            InferCase(operation: .imUserMessage, command: "给飞书的庄泓铠的飞书助手发一条消息，告诉他我正在用 PulseType"),
            InferCase(operation: .bitableApp, command: "帮我在飞书建立一个多位表格"),
            InferCase(operation: .searchDocWiki, command: "请帮我 search doc：路线图"),
            InferCase(operation: .calendarFreebusy, command: "飞书 freebusy 看看今天下午是否空闲"),
            InferCase(operation: .oauthBatchAuth, command: "Feishu batch auth now"),
            InferCase(operation: .wikiSpaceNode, command: "需要读取 wiki space node 信息")
        ]

        for item in variants {
            let inferred = FeishuCanonicalOperation.infer(from: item.command)
            XCTAssertEqual(
                inferred,
                item.operation,
                "variant command=\(item.command)"
            )
        }
    }

    func testExecuteRoutesAll35OperationsToExpectedLarkCommands() async throws {
        let fixture = try makeExecutableFixture(
            fileName: "lark-cli",
            script: """
#!/bin/sh
echo "$@"
if echo "$@" | grep -q "calendar +create"; then
  echo '{"ok":true,"identity":"user","data":{"event_id":"evt_route_123"}}'
elif echo "$@" | grep -q "calendar event.attendees create"; then
  echo '{"ok":true,"identity":"user","data":{"event_id":"evt_attendee_123"}}'
elif echo "$@" | grep -q "base +base-create"; then
  echo '{"ok":true,"identity":"user","data":{"app_token":"basc_route_123"}}'
elif echo "$@" | grep -q "docs +create"; then
  echo '{"ok":true,"identity":"user","data":{"document_id":"doc_route_123"}}'
elif echo "$@" | grep -q "docs +update"; then
  echo '{"ok":true,"identity":"user","data":{"document_id":"doc_route_456"}}'
elif echo "$@" | grep -q "drive +add-comment"; then
  echo '{"ok":true,"identity":"user","data":{"document_id":"doc_comment_123"}}'
elif echo "$@" | grep -q "docs +media-"; then
  echo '{"ok":true,"identity":"user","data":{"file_token":"media_route_123"}}'
elif echo "$@" | grep -q "drive +upload"; then
  echo '{"ok":true,"identity":"user","data":{"file_token":"file_route_123"}}'
elif echo "$@" | grep -q "im +messages-send"; then
  echo '{"ok":true,"identity":"bot","data":{"message_id":"om_route_123"}}'
elif echo "$@" | grep -q "task +comment"; then
  echo '{"ok":true,"identity":"user","data":{"task_id":"task_comment_123"}}'
elif echo "$@" | grep -q "task subtasks create"; then
  echo '{"ok":true,"identity":"user","data":{"task_id":"subtask_route_123"}}'
elif echo "$@" | grep -q "task +update"; then
  echo '{"ok":true,"identity":"user","data":{"task_id":"task_route_123"}}'
elif echo "$@" | grep -q "task +tasklist-create"; then
  echo '{"ok":true,"identity":"user","data":{"tasklist_id":"tasklist_route_123"}}'
fi
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

        let routeCases: [RouteCase] = [
            RouteCase(operation: .bitableApp, command: "飞书查看多维表格 app", explicitArguments: ["--probe", "1"], expectedTokens: ["base +base-get"]),
            RouteCase(operation: .bitableAppTable, command: "飞书查看数据表", explicitArguments: ["--probe", "1"], expectedTokens: ["base +table-list"]),
            RouteCase(operation: .bitableAppTableField, command: "飞书查看字段", explicitArguments: ["--probe", "1"], expectedTokens: ["base +field-list"]),
            RouteCase(operation: .bitableAppTableRecord, command: "飞书查看记录", explicitArguments: ["--probe", "1"], expectedTokens: ["base +record-list"]),
            RouteCase(operation: .bitableAppTableView, command: "飞书查看视图", explicitArguments: ["--probe", "1"], expectedTokens: ["base +view-list"]),
            RouteCase(operation: .calendarCalendar, command: "飞书看今天日历", explicitArguments: [], expectedTokens: ["calendar +agenda"]),
            RouteCase(operation: .calendarEvent, command: "飞书看今天日程", explicitArguments: [], expectedTokens: ["calendar +agenda"]),
            RouteCase(operation: .calendarEventAttendee, command: "飞书添加参会人", explicitArguments: ["--probe", "1"], expectedTokens: ["calendar event.attendees create"]),
            RouteCase(operation: .calendarFreebusy, command: "飞书查忙闲", explicitArguments: ["--start", "2026-03-29T15:00:00+08:00", "--end", "2026-03-29T15:30:00+08:00"], expectedTokens: ["calendar +freebusy"]),
            RouteCase(operation: .chat, command: "飞书搜索群聊 产品群", explicitArguments: [], expectedTokens: ["im +chat-search", "--query"]),
            RouteCase(operation: .chatMembers, command: "飞书查看群成员 产品群", explicitArguments: ["--params", "{\"chat_id\":\"oc_1\"}"], expectedTokens: ["im chat.members get"]),
            RouteCase(operation: .createDoc, command: "飞书创建文档", explicitArguments: ["--probe", "1"], expectedTokens: ["docs +create"]),
            RouteCase(operation: .docComments, command: "飞书文档评论", explicitArguments: ["--probe", "1"], expectedTokens: ["drive +add-comment"]),
            RouteCase(operation: .docMedia, command: "飞书下载文档媒体", explicitArguments: ["--probe", "1"], expectedTokens: ["docs +media-download"]),
            RouteCase(operation: .driveFile, command: "飞书上传云盘文件", explicitArguments: ["--probe", "1"], expectedTokens: ["drive +upload"]),
            RouteCase(operation: .fetchDoc, command: "飞书读取文档", explicitArguments: ["--probe", "1"], expectedTokens: ["docs +fetch"]),
            RouteCase(operation: .getUser, command: "飞书获取我的信息", explicitArguments: [], expectedTokens: ["contact +get-user"]),
            RouteCase(operation: .imBotImage, command: "飞书机器人发图片", explicitArguments: ["--chat-id", "oc_1", "--image", "img_1"], expectedTokens: ["im +messages-send", "--as bot"]),
            RouteCase(operation: .imUserFetchResource, command: "飞书下载消息资源", explicitArguments: ["--probe", "1"], expectedTokens: ["im +messages-resources-download"]),
            RouteCase(operation: .imUserGetMessages, command: "飞书查看消息列表", explicitArguments: ["--probe", "1"], expectedTokens: ["im +chat-messages-list"]),
            RouteCase(operation: .imUserGetThreadMessages, command: "飞书查看线程消息", explicitArguments: ["--probe", "1"], expectedTokens: ["im +threads-messages-list"]),
            RouteCase(operation: .imUserMessage, command: "飞书给群发消息", explicitArguments: ["--chat-id", "oc_1", "--text", "hi"], expectedTokens: ["im +messages-send", "--as bot"]),
            RouteCase(operation: .imUserSearchMessages, command: "飞书搜索消息 PulseType", explicitArguments: [], expectedTokens: ["im +messages-search"]),
            RouteCase(operation: .oauth, command: "飞书授权状态", explicitArguments: [], expectedTokens: ["auth status"]),
            RouteCase(operation: .oauthBatchAuth, command: "飞书批量授权", explicitArguments: [], expectedTokens: ["auth login --recommend --no-wait"]),
            RouteCase(operation: .searchDocWiki, command: "飞书搜索文档 路线图", explicitArguments: [], expectedTokens: ["docs +search"]),
            RouteCase(operation: .searchUser, command: "飞书搜索用户 庄泓铠", explicitArguments: [], expectedTokens: ["contact +search-user", "--query"]),
            RouteCase(operation: .sheet, command: "飞书表格读取", explicitArguments: ["--probe", "1"], expectedTokens: ["sheets +read"]),
            RouteCase(operation: .taskComment, command: "飞书任务评论", explicitArguments: ["--probe", "1"], expectedTokens: ["task +comment"]),
            RouteCase(operation: .taskSubtask, command: "飞书创建子任务", explicitArguments: ["--probe", "1"], expectedTokens: ["task subtasks create"]),
            RouteCase(operation: .taskTask, command: "飞书更新任务", explicitArguments: ["--probe", "1"], expectedTokens: ["task +update"]),
            RouteCase(operation: .taskTasklist, command: "飞书创建任务列表", explicitArguments: ["--probe", "1"], expectedTokens: ["task +tasklist-create"]),
            RouteCase(operation: .updateDoc, command: "飞书更新文档", explicitArguments: ["--probe", "1"], expectedTokens: ["docs +update"]),
            RouteCase(operation: .wikiSpace, command: "飞书 wiki space", explicitArguments: ["--params", "{\"token\":\"wiki_1\"}"], expectedTokens: ["wiki spaces get_node"]),
            RouteCase(operation: .wikiSpaceNode, command: "飞书读取 wiki 节点", explicitArguments: ["--probe", "1"], expectedTokens: ["wiki spaces get_node"])
        ]

        XCTAssertEqual(routeCases.count, FeishuCanonicalOperation.allCases.count)

        for item in routeCases {
            let result = await provider.execute(
                operation: item.operation,
                spokenCommand: item.command,
                explicitArguments: item.explicitArguments,
                availability: availability
            )

            switch result {
            case let .success(success):
                let output = success.outputText ?? ""
                for token in item.expectedTokens {
                    XCTAssertTrue(
                        output.contains(token),
                        "operation=\(item.operation.rawValue), expected token=\(token), output=\(output)"
                    )
                }
            case let .failure(error):
                XCTFail("operation=\(item.operation.rawValue) expected success but got error: \(error)")
            }
        }
    }

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

    func testBitableCreateCommandAutoBuildsBaseCreateArguments() async throws {
        let fixture = try makeExecutableFixture(
            fileName: "lark-cli",
            script: """
#!/bin/sh
echo "$@"
echo '{"ok":true,"identity":"user","data":{"app_token":"basc_created_123"}}'
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
            operation: .bitableApp,
            spokenCommand: "帮我在飞书建立一个多位表格",
            explicitArguments: [],
            availability: availability
        )

        switch result {
        case let .success(success):
            let output = success.outputText ?? ""
            XCTAssertTrue(output.contains("base +base-create"))
            XCTAssertTrue(output.contains("--name"))
            XCTAssertFalse(output.contains("--help"))
        case let .failure(error):
            XCTFail("expected success but got error: \(error)")
        }
    }

    func testCalendarEventNaturalLanguageBuildsCreateArgumentsWithoutHelp() async throws {
        let fixture = try makeExecutableFixture(
            fileName: "lark-cli",
            script: """
#!/bin/sh
echo "$@"
echo '{"ok":true,"identity":"user","data":{"event_id":"evt_123","summary":"上课"}}'
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

    func testCalendarEventIgnoresIncompleteExplicitArgumentsAndFallsBackToInference() async throws {
        let fixture = try makeExecutableFixture(
            fileName: "lark-cli",
            script: """
#!/bin/sh
echo "$@"
echo '{"ok":true,"identity":"user","data":{"event_id":"evt_456","summary":"上课"}}'
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
            spokenCommand: "飞书，今天下午三点添加一个上课日程。",
            explicitArguments: ["--summary", "--start", "--end"],
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
            XCTAssertFalse(output.contains("calendar +create --summary --start --end"))
        case let .failure(error):
            XCTFail("expected success but got error: \(error)")
        }
    }

    func testCalendarCreateFailsWhenStructuredEnvelopeMissing() async throws {
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
        case .success:
            XCTFail("expected failure when structured envelope is missing")
        case let .failure(error):
            XCTAssertEqual(error.code, .toolExecutionFailed)
            XCTAssertTrue(error.userMessage.contains("结构化日程结果"))
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

    func testExecuteMapsUnknownFlagFailureToReadableMessage() async throws {
        let fixture = try makeExecutableFixture(
            fileName: "lark-cli",
            script: """
#!/bin/sh
echo "unknown flag: --bad" 1>&2
exit 2
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
            spokenCommand: "给测试群发消息",
            explicitArguments: ["--bad", "1"],
            availability: availability
        )

        switch result {
        case .success:
            XCTFail("expected failure but got success")
        case let .failure(error):
            XCTAssertEqual(error.code, .toolExecutionFailed)
            XCTAssertTrue(error.userMessage.contains("参数格式"))
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

    func testIMUserMessageReturnsAlternativesWhenRecipientIsAmbiguous() async throws {
        let fixture = try makeExecutableFixture(
            fileName: "lark-cli",
            script: """
#!/bin/sh
if [ "$1" = "im" ] && [ "$2" = "+chat-search" ]; then
  echo '{"ok":true,"identity":"user","data":{"chats":[{"chat_id":"oc_123abc","name":"测试群"},{"chat_id":"oc_456def","name":"测试群-备份"}]}}'
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
        case .success:
            XCTFail("expected ambiguity failure but got success")
        case let .failure(error):
            XCTAssertEqual(error.code, .intentParseFailed)
            XCTAssertTrue(error.userMessage.contains("找到多个群聊"))
            XCTAssertTrue(error.userMessage.contains("测试群"))
            XCTAssertTrue(error.userMessage.contains("测试群-备份"))
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

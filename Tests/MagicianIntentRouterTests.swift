import XCTest
@testable import PulseType

@MainActor
final class MagicianIntentRouterTests: XCTestCase {
    private struct FeishuRouteCase {
        let operation: String
        let command: String
    }

    private let fullFeishuRouteCases: [FeishuRouteCase] = [
        FeishuRouteCase(operation: "feishu_bitable_app", command: "飞书打开多维表格 app"),
        FeishuRouteCase(operation: "feishu_bitable_app_table", command: "飞书查看数据表 table list"),
        FeishuRouteCase(operation: "feishu_bitable_app_table_field", command: "飞书查看字段配置"),
        FeishuRouteCase(operation: "feishu_bitable_app_table_record", command: "飞书查看记录列表"),
        FeishuRouteCase(operation: "feishu_bitable_app_table_view", command: "飞书查看视图 table view"),
        FeishuRouteCase(operation: "feishu_calendar_calendar", command: "飞书查看日历"),
        FeishuRouteCase(operation: "feishu_calendar_event", command: "飞书今天下午三点添加一个上课日程"),
        FeishuRouteCase(operation: "feishu_calendar_event_attendee", command: "飞书邀请参会人 attendee"),
        FeishuRouteCase(operation: "feishu_calendar_freebusy", command: "飞书查忙闲 freebusy"),
        FeishuRouteCase(operation: "feishu_chat", command: "飞书搜索群聊 chat"),
        FeishuRouteCase(operation: "feishu_chat_members", command: "飞书查看群成员"),
        FeishuRouteCase(operation: "feishu_create_doc", command: "飞书创建文档"),
        FeishuRouteCase(operation: "feishu_doc_comments", command: "飞书添加评论"),
        FeishuRouteCase(operation: "feishu_doc_media", command: "飞书文档图片 media 插入"),
        FeishuRouteCase(operation: "feishu_drive_file", command: "飞书上传文件到云盘 drive file"),
        FeishuRouteCase(operation: "feishu_fetch_doc", command: "飞书读取文档"),
        FeishuRouteCase(operation: "feishu_get_user", command: "飞书获取用户信息"),
        FeishuRouteCase(operation: "feishu_im_bot_image", command: "飞书发图片 bot image"),
        FeishuRouteCase(operation: "feishu_im_user_fetch_resource", command: "飞书下载消息资源"),
        FeishuRouteCase(operation: "feishu_im_user_get_messages", command: "飞书查看消息列表"),
        FeishuRouteCase(operation: "feishu_im_user_get_thread_messages", command: "飞书查看线程消息"),
        FeishuRouteCase(operation: "feishu_im_user_message", command: "飞书发送消息给同事"),
        FeishuRouteCase(operation: "feishu_im_user_search_messages", command: "飞书搜索消息"),
        FeishuRouteCase(operation: "feishu_oauth", command: "飞书 oauth 授权状态"),
        FeishuRouteCase(operation: "feishu_oauth_batch_auth", command: "飞书批量授权"),
        FeishuRouteCase(operation: "feishu_search_doc_wiki", command: "飞书搜文档 search wiki"),
        FeishuRouteCase(operation: "feishu_search_user", command: "飞书查人 search user"),
        FeishuRouteCase(operation: "feishu_sheet", command: "飞书表格 sheet 读取"),
        FeishuRouteCase(operation: "feishu_task_comment", command: "飞书任务评论"),
        FeishuRouteCase(operation: "feishu_task_subtask", command: "飞书创建子任务"),
        FeishuRouteCase(operation: "feishu_task_task", command: "飞书管理任务 task"),
        FeishuRouteCase(operation: "feishu_task_tasklist", command: "飞书创建任务列表 tasklist"),
        FeishuRouteCase(operation: "feishu_update_doc", command: "飞书更新文档"),
        FeishuRouteCase(operation: "feishu_wiki_space", command: "飞书 wiki space"),
        FeishuRouteCase(operation: "feishu_wiki_space_node", command: "飞书 wiki 节点")
    ]

    func testHeuristicRouterRecognizesAll35FeishuOperationsInCommandOnlyMode() async throws {
        let router = HeuristicMagicianIntentRouter()
        XCTAssertEqual(fullFeishuRouteCases.count, FeishuCanonicalOperation.allCases.count)

        for item in fullFeishuRouteCases {
            let intent = try await router.route(
                command: item.command,
                selection: nil,
                enabledFeatures: [.feishuCLI]
            )

            XCTAssertEqual(intent.intent, .feishuCLI, "command=\(item.command)")
            XCTAssertEqual(intent.sourceText, "", "command=\(item.command)")
            XCTAssertEqual(intent.params.cliOperation, item.operation, "command=\(item.command)")
        }
    }

    func testHeuristicRouterRejectsRemovedSearchIntent() async {
        let router = HeuristicMagicianIntentRouter()

        do {
            _ = try await router.route(
                command: "帮我搜索一下",
                selection: "OpenAI o3",
                enabledFeatures: [.createNote]
            )
            XCTFail("Expected removed feature error")
        } catch let error as MagicianError {
            XCTAssertEqual(error.code, .intentParseFailed)
            XCTAssertTrue(error.userMessage.contains("快速搜索已下线"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHeuristicRouterAllowsTextTransformWithoutSelectionInCommandMode() async throws {
        let router = HeuristicMagicianIntentRouter()

        let intent = try await router.route(
            command: "帮我润色一下",
            selection: nil,
            enabledFeatures: [.textTransform]
        )

        XCTAssertEqual(intent.intent, .textTransform)
        XCTAssertEqual(intent.sourceText, "帮我润色一下")
    }

    func testHeuristicRouterPrioritizesFeishuWhenSelectionExists() async throws {
        let router = HeuristicMagicianIntentRouter()
        let intent = try await router.route(
            command: "把这段内容写到飞书日程里",
            selection: "4月1日下午三点 路线图评审",
            enabledFeatures: [.textTransform, .createEvent, .feishuCLI]
        )

        XCTAssertEqual(intent.intent, .feishuCLI)
        XCTAssertEqual(intent.params.cliOperation, "feishu_calendar_event")
    }

    func testHeuristicRouterDefaultsUnspecifiedScheduleToSystemCalendar() async throws {
        let router = HeuristicMagicianIntentRouter()
        let intent = try await router.route(
            command: "添加一个下午三点的上课日程",
            selection: nil,
            enabledFeatures: [.createEvent, .feishuCLI]
        )

        XCTAssertEqual(intent.intent, .createEvent)
    }

    func testHeuristicRouterRoutesNoSelectionFeishuCommandToCLIIntent() async throws {
        let router = HeuristicMagicianIntentRouter()

        let intent = try await router.route(
            command: "飞书查今天议程",
            selection: nil,
            enabledFeatures: [.feishuCLI]
        )

        XCTAssertEqual(intent.intent, .feishuCLI)
        XCTAssertEqual(intent.sourceText, "")
        XCTAssertNotNil(intent.params.cliOperation)
    }

    func testHeuristicRouterAllowsFeishuSearchIntentInCLIContext() async throws {
        let router = HeuristicMagicianIntentRouter()

        let intent = try await router.route(
            command: "飞书搜索消息 路线图",
            selection: nil,
            enabledFeatures: [.feishuCLI]
        )

        XCTAssertEqual(intent.intent, .feishuCLI)
        XCTAssertEqual(intent.params.cliOperation, "feishu_im_user_search_messages")
    }

    func testHeuristicWorkflowPlannerKeepsFeishuCommandOnlyAsSingleStep() async throws {
        let planner = HeuristicMagicianWorkflowPlanner()
        let command = "飞书，今天下午三点添加一个上课的日程。"

        let plan = try await planner.plan(
            command: command,
            selection: nil,
            enabledFeatures: [.feishuCLI]
        )

        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps[0].feature, .feishuCLI)
        XCTAssertEqual(plan.steps[0].command, command)
        XCTAssertEqual(plan.steps[0].params.cliOperation, "feishu_calendar_event")
    }

    func testHeuristicWorkflowPlannerSupportsMultiStepInCommandMode() async throws {
        let planner = HeuristicMagicianWorkflowPlanner()
        let plan = try await planner.plan(
            command: "先建飞书多位表格，然后分析一下今年各国的GDP",
            selection: nil,
            enabledFeatures: [.feishuCLI, .textTransform]
        )

        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].feature, .feishuCLI)
        XCTAssertEqual(plan.steps[0].inputBinding, .commandOnly)
        XCTAssertEqual(plan.steps[1].feature, .textTransform)
        XCTAssertEqual(plan.steps[1].inputBinding, .previousOutput)
    }

    func testSchemaValidatorRejectsDisabledIntent() {
        let validator = MagicianIntentSchemaValidator()
        let intent = MagicianIntent(
            intent: .createEvent,
            confidence: 0.9,
            sourceText: "周五下午开会",
            params: .empty
        )

        XCTAssertThrowsError(
            try validator.validate(intent, enabledFeatures: [.createNote])
        ) { error in
            let magicianError = error as? MagicianError
            XCTAssertEqual(magicianError?.code, .intentParseFailed)
        }
    }

    func testLLMRouterFailsWhenRewriteConfigurationInvalid() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )
        providerStore.updateTextModel("")

        let generationProvider = TrackingTextGenerationProvider(
            outputText: """
            {"intent":"create_note","confidence":0.8,"sourceText":"x","params":{"noteBody":"x"}}
            """
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        do {
            _ = try await router.route(
                command: "记到备忘录",
                selection: "OpenAI",
                enabledFeatures: [.createNote]
            )
            XCTFail("Expected intentParseFailed error")
        } catch let error as MagicianError {
            XCTAssertEqual(error.code, .intentParseFailed)
            XCTAssertTrue(error.userMessage.contains("文本模型"))
            XCTAssertEqual(generationProvider.callCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLLMRouterRejectsRemovedSearchIntentBeforeCallingModel() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: """
            {"intent":"create_note","confidence":0.8,"sourceText":"x","params":{"noteBody":"x"}}
            """
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        do {
            _ = try await router.route(
                command: "帮我搜索一下",
                selection: "OpenAI 最新发布",
                enabledFeatures: [.createNote]
            )
            XCTFail("Expected removed feature error")
        } catch let error as MagicianError {
            XCTAssertEqual(error.code, .intentParseFailed)
            XCTAssertTrue(error.userMessage.contains("快速搜索已下线"))
            XCTAssertEqual(generationProvider.callCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLLMRouterFailsWhenRewriteAPIKeyMissing() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: [:])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: """
            {"intent":"create_note","confidence":0.8,"sourceText":"x","params":{"noteBody":"x"}}
            """
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        do {
            _ = try await router.route(
                command: "记到备忘录",
                selection: "会议纪要",
                enabledFeatures: [.createNote]
            )
            XCTFail("Expected intentParseFailed error")
        } catch let error as MagicianError {
            XCTAssertEqual(error.code, .intentParseFailed)
            XCTAssertTrue(error.userMessage.contains("API"))
            XCTAssertEqual(generationProvider.callCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLLMRouterUsesCLIModelContextForFeishuCommandMode() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-text-fallback"])
        )
        providerStore.updateCLITextModel("deepseek-chat")

        let generationProvider = TrackingTextGenerationProvider(
            outputTexts: [
                #"{"intent":"feishu_cli","confidence":0.93}"#,
                #"{"sourceText":"","params":{"cliOperation":"feishu_calendar_event","cliArguments":[]}}"#
            ]
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let intent = try await router.route(
            command: "飞书查今天议程",
            selection: nil,
            enabledFeatures: [.feishuCLI]
        )

        XCTAssertEqual(intent.intent, .feishuCLI)
        XCTAssertEqual(intent.sourceText, "")
        XCTAssertEqual(intent.params.cliOperation, "feishu_calendar_event")
        XCTAssertEqual(generationProvider.callCount, 2)
        XCTAssertTrue(generationProvider.requests[1].systemPrompt.contains("Feishu CLI intent extractor"))
    }

    func testLLMRouterAllowsFeishuSearchIntentWithoutRemovedSearchGuard() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-cli-search"])
        )
        providerStore.updateCLITextModel("deepseek-chat")

        let generationProvider = TrackingTextGenerationProvider(
            outputTexts: [
                #"{"intent":"feishu_cli","confidence":0.91}"#,
                #"{"sourceText":"","params":{"cliOperation":"feishu_im_user_search_messages","cliArguments":["--query","路线图"]}}"#
            ]
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let intent = try await router.route(
            command: "飞书搜索消息 路线图",
            selection: nil,
            enabledFeatures: [.feishuCLI]
        )

        XCTAssertEqual(intent.intent, .feishuCLI)
        XCTAssertEqual(intent.params.cliOperation, "feishu_im_user_search_messages")
        XCTAssertEqual(generationProvider.callCount, 2)
    }

    func testLLMRouterParsesJSONFromCodeFence() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputTexts: [
                #"{"intent":"create_note","confidence":0.91}"#,
                """
                ```json
                {"sourceText":"记录这段内容","params":{"noteBody":"记录这段内容"}}
                ```
                """
            ]
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let intent = try await router.route(
            command: "记到备忘录",
            selection: "记录这段内容",
            enabledFeatures: [.createNote]
        )

        XCTAssertEqual(intent.intent, .createNote)
        XCTAssertEqual(intent.params.noteBody, "记录这段内容")
        XCTAssertEqual(generationProvider.callCount, 2)
    }

    func testLLMRouterNormalizesInstructionPhraseToSelectionForCreateNote() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputTexts: [
                #"{"intent":"create_note","confidence":0.83}"#,
                #"{"sourceText":"帮我写进备忘录","params":{"noteBody":"帮我写进备忘录"}}"#
            ]
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let intent = try await router.route(
            command: "帮我写进备忘录",
            selection: "周五 15:00 在 A 会议室评审 PRD",
            enabledFeatures: [.createNote]
        )

        XCTAssertEqual(intent.intent, .createNote)
        XCTAssertEqual(intent.sourceText, "周五 15:00 在 A 会议室评审 PRD")
        XCTAssertEqual(intent.params.noteBody, "周五 15:00 在 A 会议室评审 PRD")
        XCTAssertEqual(generationProvider.callCount, 2)
    }

    func testLLMRouterNormalizesInstructionPhraseToSelectionForCreateEvent() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputTexts: [
                #"{"intent":"create_event","confidence":0.82}"#,
                #"{"sourceText":"帮我建立日程","params":{"title":"帮我建立日程"}}"#
            ]
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let selectionText = "4月1日 14:30 在上海办公室和产品团队开路标会"
        let intent = try await router.route(
            command: "帮我建立日程",
            selection: selectionText,
            enabledFeatures: [.createEvent]
        )

        XCTAssertEqual(intent.intent, .createEvent)
        XCTAssertEqual(intent.sourceText, selectionText)
        XCTAssertEqual(intent.params.title, String(selectionText.prefix(60)))
        XCTAssertEqual(generationProvider.callCount, 2)
    }

    func testLLMRouterUsesDedicatedMailExtractorAndComposer() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputTexts: [
                #"{"intent":"compose_email_draft","confidence":0.9}"#,
                #"{"sourceText":"路线图同步","params":{"mailRecipientHints":["小庄"],"mailDeliveryMode":"auto_send_if_resolved"}}"#,
                #"{"mailSubject":"路线图同步","mailBody":"小庄你好，\n\n我把路线图同步的关键信息整理如下：\n- 明天下午三点在 A 会议室一起过一遍路线图。\n\n如有问题我们现场对齐。"}"#
            ]
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let selection = "大家好，明天下午三点我们在 A 会议室过一遍路线图。"
        let intent = try await router.route(
            command: "发给小庄",
            selection: selection,
            enabledFeatures: [.composeEmailDraft]
        )

        XCTAssertEqual(intent.intent, .composeEmailDraft)
        XCTAssertEqual(intent.sourceText, selection)
        XCTAssertEqual(intent.params.mailBody, "小庄你好，\n\n我把路线图同步的关键信息整理如下：\n- 明天下午三点在 A 会议室一起过一遍路线图。\n\n如有问题我们现场对齐。")
        XCTAssertEqual(intent.params.mailRecipientHints, ["小庄"])
        XCTAssertEqual(intent.params.mailDeliveryMode, .autoSendIfResolved)
        XCTAssertEqual(intent.params.mailSubject, "路线图同步")
        XCTAssertEqual(generationProvider.callCount, 3)
        XCTAssertTrue(generationProvider.requests[1].systemPrompt.contains("mail intent extractor"))
        XCTAssertTrue(generationProvider.requests[2].systemPrompt.contains("mail composer"))
    }

    func testLLMRouterKeepsDraftOnlyWhenMailCommandExplicitlyAsksForDraft() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputTexts: [
                #"{"intent":"compose_email_draft","confidence":0.87}"#,
                #"{"sourceText":"帮我草拟一封邮件","params":{"mailTo":["team@example.com"],"mailDeliveryMode":"draft_only"}}"#,
                #"{"mailSubject":"活动通知","mailBody":"大家好，\n\n这里是本周活动通知，请查收。"}"#
            ]
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let intent = try await router.route(
            command: "帮我草拟一封邮件给 team@example.com",
            selection: "",
            enabledFeatures: [.composeEmailDraft]
        )

        XCTAssertEqual(intent.intent, .composeEmailDraft)
        XCTAssertEqual(intent.params.mailTo, ["team@example.com"])
        XCTAssertEqual(intent.params.mailDeliveryMode, .draftOnly)
        XCTAssertEqual(intent.params.mailSubject, "活动通知")
        XCTAssertEqual(intent.params.mailBody, "大家好，\n\n这里是本周活动通知，请查收。")
    }

    func testLLMRouterStopsAfterClassifierForTextTransform() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputTexts: [
                #"{"intent":"text_transform","confidence":0.88}"#
            ]
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let intent = try await router.route(
            command: "转换为中国古诗风格",
            selection: "春风又绿江南岸",
            enabledFeatures: [.textTransform]
        )

        XCTAssertEqual(intent.intent, .textTransform)
        XCTAssertEqual(intent.sourceText, "春风又绿江南岸")
        XCTAssertEqual(generationProvider.callCount, 1)
    }

    func testLLMRouterUsesDedicatedClassifierThenNotePrompt() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputTexts: [
                #"{"intent":"create_note","confidence":0.91}"#,
                #"{"sourceText":"记录这段内容","params":{"title":"会议纪要","noteBody":"记录这段内容"}}"#
            ]
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let intent = try await router.route(
            command: "帮我写进备忘录",
            selection: "记录这段内容",
            enabledFeatures: [.createNote]
        )

        XCTAssertEqual(intent.intent, .createNote)
        XCTAssertEqual(generationProvider.callCount, 2)
        XCTAssertTrue(generationProvider.requests[0].systemPrompt.contains("intent classifier"))
        XCTAssertTrue(generationProvider.requests[1].systemPrompt.contains("note capture extractor"))
        XCTAssertFalse(generationProvider.requests[0].systemPrompt.contains("App-specific instruction"))
        XCTAssertFalse(generationProvider.requests[1].systemPrompt.contains("User preference system instruction"))
    }

    func testSchemaValidatorAllowsCommandFallbackWithoutSelection() throws {
        let validator = MagicianIntentSchemaValidator()
        let validated = try validator.validate(
            MagicianIntent(
                intent: .createNote,
                confidence: 0.81,
                sourceText: "",
                params: .empty
            ),
            enabledFeatures: [.createNote],
            command: "记一下周五下午和产品开会",
            selection: nil
        )

        XCTAssertEqual(validated.sourceText, "")
        XCTAssertEqual(validated.params.noteBody, "周五下午和产品开会")
    }

    func testSchemaValidatorUsesSelectionAsMailContentInsteadOfCommand() throws {
        let validator = MagicianIntentSchemaValidator()
        let selection = "未来学部心晴驿站观影活动邀请：3 月 28 日晚 7 点，M 栋 901。"
        let validated = try validator.validate(
            MagicianIntent(
                intent: .composeEmailDraft,
                confidence: 0.89,
                sourceText: "",
                params: MagicianIntentParams(
                    mailRecipientHints: ["小庄"],
                    mailDeliveryMode: .autoSendIfResolved,
                    mailSubject: "帮我写一个邮件",
                    mailBody: "发给小庄并发送"
                )
            ),
            enabledFeatures: [.composeEmailDraft],
            command: "发给小庄并发送",
            selection: selection
        )

        XCTAssertEqual(validated.sourceText, selection)
        XCTAssertEqual(validated.params.mailBody, selection)
        XCTAssertEqual(validated.params.mailSubject, String(selection.prefix(48)))
    }

    func testLLMRouterRejectsInvalidJSONWithoutHeuristicFallback() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: "这不是合法 JSON"
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        do {
            _ = try await router.route(
                command: "记到备忘录",
                selection: "OpenAI o3",
                enabledFeatures: [.createNote]
            )
            XCTFail("Expected intentParseFailed error")
        } catch let error as MagicianError {
            XCTAssertEqual(error.code, .intentParseFailed)
            XCTAssertEqual(generationProvider.callCount, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLLMRouterFallsBackToHeuristicInCLICommandModeWhenLLMExtractionInvalid() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-cli-fallback"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputTexts: [
                #"{"intent":"feishu_cli","confidence":0.92}"#,
                "not-json"
            ]
        )

        let router = LLMMagicianIntentRouter(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider
        )

        let intent = try await router.route(
            command: "飞书，今天下午三点添加一个上课的日程。",
            selection: nil,
            enabledFeatures: [.feishuCLI]
        )

        XCTAssertEqual(intent.intent, .feishuCLI)
        XCTAssertEqual(intent.params.cliOperation, "feishu_calendar_event")
        XCTAssertEqual(generationProvider.callCount, 2)
    }

    func testLLMWorkflowPlannerBuildsOrderedSteps() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: """
            {"steps":[{"feature":"create_note","command":"先写进备忘录","inputBinding":"selection_text"},{"feature":"compose_email_draft","command":"再发给小庄","inputBinding":"previous_output"}],"confidence":0.93,"rationale":"two_step_flow"}
            """
        )

        let planner = LLMMagicianWorkflowPlanner(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider,
            intentRouter: HeuristicMagicianIntentRouter()
        )

        let plan = try await planner.plan(
            command: "先写进备忘录，然后发给小庄",
            selection: "路线图同步纪要",
            enabledFeatures: [.createNote, .composeEmailDraft]
        )

        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].feature, .createNote)
        XCTAssertEqual(plan.steps[1].feature, .composeEmailDraft)
        XCTAssertEqual(plan.steps[0].inputBinding, .selectionText)
        XCTAssertEqual(plan.steps[1].inputBinding, .previousOutput)
        XCTAssertEqual(generationProvider.callCount, 1)
    }

    func testLLMWorkflowPlannerFallsBackToHeuristicWhenPlannerOutputInvalid() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: "invalid json"
        )

        let planner = LLMMagicianWorkflowPlanner(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider,
            intentRouter: HeuristicMagicianIntentRouter(),
            fallbackPlanner: HeuristicMagicianWorkflowPlanner(intentRouter: HeuristicMagicianIntentRouter())
        )

        let plan = try await planner.plan(
            command: "先写进备忘录，然后发给小庄",
            selection: "路线图同步纪要",
            enabledFeatures: [.createNote, .composeEmailDraft]
        )

        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].feature, .createNote)
        XCTAssertEqual(plan.steps[1].feature, .composeEmailDraft)
        XCTAssertEqual(generationProvider.callCount, 1)
    }

    func testLLMWorkflowPlannerPrefersHeuristicMultiStepPlanWhenLLMCollapsesExplicitWorkflow() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: """
            {"steps":[{"feature":"create_note","command":"写进备忘录","inputBinding":"previous_output"}],"confidence":0.81,"rationale":"collapsed"}
            """
        )

        let planner = LLMMagicianWorkflowPlanner(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider,
            intentRouter: HeuristicMagicianIntentRouter(),
            fallbackPlanner: HeuristicMagicianWorkflowPlanner(intentRouter: HeuristicMagicianIntentRouter())
        )

        let plan = try await planner.plan(
            command: "翻译成日语并写进备忘录",
            selection: "Hello world",
            enabledFeatures: [.textTransform, .createNote]
        )

        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].feature, .textTransform)
        XCTAssertEqual(plan.steps[1].feature, .createNote)
        XCTAssertEqual(plan.steps[0].inputBinding, .selectionText)
        XCTAssertEqual(plan.steps[1].inputBinding, .previousOutput)
        XCTAssertEqual(generationProvider.callCount, 1)
    }

    func testLLMWorkflowPlannerUsesOriginalCommandForFeishuStepWhenDraftIsTooShort() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let providerStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStore(storage: ["text.primary": "sk-test"])
        )

        let generationProvider = TrackingTextGenerationProvider(
            outputText: """
            {"steps":[{"feature":"feishu_cli","command":"添加","inputBinding":"command_only"}],"confidence":0.87,"rationale":"single_step_cli"}
            """
        )

        let planner = LLMMagicianWorkflowPlanner(
            providerSettingsStore: providerStore,
            generationProvider: generationProvider,
            intentRouter: HeuristicMagicianIntentRouter(),
            fallbackPlanner: FailingWorkflowPlanner()
        )

        let command = "飞书，今天下午三点添加一个上课的日程。"
        let plan = try await planner.plan(
            command: command,
            selection: nil,
            enabledFeatures: [.feishuCLI]
        )

        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps[0].feature, .feishuCLI)
        XCTAssertEqual(plan.steps[0].command, command)
        XCTAssertEqual(plan.steps[0].params.cliOperation, "feishu_calendar_event")
        XCTAssertEqual(generationProvider.callCount, 1)
    }

    func testStepRegistryRejectsPlansLongerThanFiveSteps() {
        let registry = MagicianStepRegistry()
        let plan = MagicianWorkflowPlan(
            steps: (1...6).map { index in
                MagicianWorkflowStep(
                    stepID: "step-\(index)",
                    feature: .createNote,
                    params: .empty,
                    inputBinding: .selectionText
                )
            },
            confidence: 0.8
        )

        XCTAssertThrowsError(
            try registry.validatedPlan(
                plan,
                enabledFeatures: [.createNote],
                fallbackCommand: "写进备忘录",
                fallbackSelection: "内容"
            )
        ) { error in
            let magicianError = error as? MagicianError
            XCTAssertEqual(magicianError?.code, .intentParseFailed)
        }
    }

    func testStepRegistryUsesCommandOnlyForFirstFeishuStepWithoutSelection() throws {
        let registry = MagicianStepRegistry()
        let plan = MagicianWorkflowPlan(
            steps: [
                MagicianWorkflowStep(
                    stepID: "step-1",
                    feature: .feishuCLI,
                    params: MagicianIntentParams(cliOperation: "feishu_calendar_event"),
                    inputBinding: .selectionText,
                    command: "飞书查今天议程"
                )
            ],
            confidence: 0.9
        )

        let validated = try registry.validatedPlan(
            plan,
            enabledFeatures: [.feishuCLI],
            fallbackCommand: "飞书查今天议程",
            fallbackSelection: ""
        )

        XCTAssertEqual(validated.steps.first?.feature, .feishuCLI)
        XCTAssertEqual(validated.steps.first?.inputBinding, .commandOnly)
    }

    func testStepRegistryUsesCommandOnlyForFirstTextStepWithoutSelection() throws {
        let registry = MagicianStepRegistry()
        let plan = MagicianWorkflowPlan(
            steps: [
                MagicianWorkflowStep(
                    stepID: "step-1",
                    feature: .textTransform,
                    params: .empty,
                    inputBinding: .selectionText,
                    command: "帮我总结一下这段内容"
                )
            ],
            confidence: 0.86
        )

        let validated = try registry.validatedPlan(
            plan,
            enabledFeatures: [.textTransform],
            fallbackCommand: "帮我总结一下这段内容",
            fallbackSelection: ""
        )

        XCTAssertEqual(validated.steps.first?.feature, .textTransform)
        XCTAssertEqual(validated.steps.first?.inputBinding, .commandOnly)
    }

    private var defaultsSuiteName: String {
        "MagicianIntentRouterTests.\(name)"
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Unable to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}

private final class MemoryCredentialStore: ProviderCredentialStore {
    private var storage: [String: String]

    init(storage: [String: String]) {
        self.storage = storage
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        storage[profileID]
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {
        storage[profileID] = value
    }

    func deleteAPIKey(for profileID: String) throws {
        storage.removeValue(forKey: profileID)
    }

    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool {
        storage[profileID]?.isEmpty == false
    }
}

private final class TrackingTextGenerationProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAI, .openAICompatible]
    private(set) var callCount: Int = 0
    private(set) var requests: [TextGenerationRequest] = []
    private let outputTexts: [String]

    init(outputText: String) {
        self.outputTexts = [outputText]
    }

    init(outputTexts: [String]) {
        self.outputTexts = outputTexts
    }

    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> TextGenerationResult {
        _ = configuration
        _ = apiKey
        requests.append(request)
        callCount += 1
        let outputIndex = min(callCount - 1, outputTexts.count - 1)
        return TextGenerationResult(
            providerType: .openAI,
            providerName: "Fake OpenAI",
            modelName: "fake-model",
            outputText: outputTexts[outputIndex]
        )
    }
}

private struct FailingWorkflowPlanner: MagicianWorkflowPlanning {
    func plan(
        command: String,
        selection: String?,
        enabledFeatures: Set<MagicianFeatureID>
    ) async throws -> MagicianWorkflowPlan {
        _ = command
        _ = selection
        _ = enabledFeatures
        throw MagicianError(
            code: .intentParseFailed,
            userMessage: "forced fallback failure",
            debugMessage: "forced fallback failure",
            recoverAction: nil
        )
    }
}

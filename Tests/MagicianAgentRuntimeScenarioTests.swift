import XCTest
@testable import PulseType

@MainActor
final class MagicianAgentRuntimeScenarioTests: XCTestCase {
    func testReplayUserSevenScenarios() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let llmProvider = ScenarioTextGenerationProvider()
        let toolExecutor = ScenarioToolExecutor()
        let runtime = MagicianAgentRuntimeV3(
            providerSettingsStore: fixture.providerSettingsStore,
            rewriteProviderRegistry: RewriteProviderRegistry(providers: []),
            textOutputCoordinator: fixture.textOutputCoordinator,
            skillRuleStore: fixture.skillRuleStore,
            toolExecutor: toolExecutor,
            llmProvider: llmProvider
        )

        let selectionForTranslation = """
        📣字节跳动2026实习生招聘宣讲会火热来袭！

        深圳大学城专场 宣讲会-来宣讲，强势助攻拿Offer！

        时间：3月30日 19:00
        地点:  北京大学深圳研究生院国际会议中心(J栋）

        来现场，解锁多重福利：
        业务负责人、校友现场分享！多个职类多个业务，现场双选！有机会获取“面试直通卡”
        更有多轮惊喜大奖，定制周边好礼等你来拿
        📌点击链接，即刻报名：https://xy.liepin.com/bytedance2026
        """

        struct Scenario {
            let id: Int
            let command: String
            let selectionText: String?
            let expectedFeatures: Set<MagicianFeatureID>
        }

        let scenarios: [Scenario] = [
            Scenario(id: 1, command: "播放稻香", selectionText: nil, expectedFeatures: [.controlMusic]),
            Scenario(id: 2, command: "播放跨时代", selectionText: nil, expectedFeatures: [.controlMusic]),
            Scenario(id: 3, command: "写一篇短篇小说并写进邮件", selectionText: nil, expectedFeatures: [.textTransform, .composeEmailDraft]),
            Scenario(id: 4, command: "翻译成日语并写进飞书日程", selectionText: selectionForTranslation, expectedFeatures: [.textTransform, .feishuCLI]),
            Scenario(id: 5, command: "把这9条新闻用一首七言绝句总结", selectionText: """
            1. 外交部回应Manus高管离境传闻：不了解情况，建议询问主管部门。
            2. 新疆喀什地区新设岑岭县，县政府驻新华镇。
            3. 中铁广州工程局集团因串通投标被公示，违背投标承诺。
            4. 宁夏前主席刘慧被开除党籍，涉多项违纪违法，包括结交政治骗子、搞迷信活动等。
            5. 台湾民众党前主席柯文哲一审被判17年，涉京华城案、政治献金案等。
            6. 新《殡葬管理条例》3月30日施行，禁止住宅专门存放骨灰，整治“骨灰房”乱象。
            7. 美媒称美国考虑将援乌武器转运至中东，以应对伊朗战事消耗。
            8. 土耳其油轮在黑海遭无人机袭击，从俄罗斯出发，载有原油，暂无人员伤亡。
            9. 乌克兰袭击俄罗斯维堡造船厂，击沉在建的9000吨破冰巡逻舰。
            """, expectedFeatures: [.textTransform]),
            Scenario(id: 6, command: "发消息给庄泓铠的飞书助手，跟他说这条消息来自 PulseType，很高兴认识他", selectionText: nil, expectedFeatures: [.feishuCLI]),
            Scenario(id: 7, command: "调研2025年上半年的中国进出口情况，并写成新邮件", selectionText: nil, expectedFeatures: [.textTransform, .composeEmailDraft])
        ]

        for scenario in scenarios {
            let focusContext = FocusedAppContext(
                appName: "TextEdit",
                bundleID: "com.apple.TextEdit",
                focusedRole: "AXTextArea",
                hasEditableTarget: true,
                strategyHint: "test"
            )
            let request = MagicianAgentRequest(
                traceID: "scenario-\(scenario.id)",
                command: scenario.command,
                selectionSnapshot: scenario.selectionText.map {
                    FocusedSelectionSnapshot(focusContext: focusContext, selectedText: $0)
                },
                focusContext: focusContext,
                enabledFeatures: Set(MagicianFeatureID.allCases)
            )

            let outcome = try await runtime.run(request: request, onEvent: nil)
            let featureSet = Set(outcome.steps.map(\.featureID))
            XCTAssertTrue(
                featureSet.isSuperset(of: scenario.expectedFeatures),
                "scenario \(scenario.id) features=\(featureSet) expected=\(scenario.expectedFeatures)"
            )
            XCTAssertFalse(outcome.steps.isEmpty, "scenario \(scenario.id) should have step records")
            XCTAssertFalse(outcome.finalStatusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            print(
                """
                SCENARIO_RESULT|\(scenario.id)|status=\(outcome.finalStatusMessage)|features=\(outcome.steps.map(\.featureID.rawValue).joined(separator: ","))|output=\(outcome.finalOutputText ?? "")
                """
            )
        }

        let composeCalls = toolExecutor.calls.filter { $0.intent.intent == .composeEmailDraft }
        XCTAssertGreaterThanOrEqual(composeCalls.count, 2)
        XCTAssertTrue(
            composeCalls.contains(where: { ($0.intent.params.mailBody ?? "").contains("雨夜里的路灯") }),
            "短篇小说结果应流向邮件正文"
        )
        XCTAssertTrue(
            composeCalls.contains(where: { ($0.intent.params.mailBody ?? "").contains("2025年上半年") }),
            "进出口调研结果应流向邮件正文"
        )

        let feishuCalls = toolExecutor.calls.filter { $0.intent.intent == .feishuCLI }
        XCTAssertGreaterThanOrEqual(feishuCalls.count, 2)
        XCTAssertTrue(
            feishuCalls.contains(where: {
                $0.intent.params.cliOperation == FeishuCanonicalOperation.calendarEvent.rawValue
                    && $0.context.command.contains("附加文本：")
                    && $0.context.command.contains("ByteDance")
            }),
            "翻译文本应拼接到飞书日程命令上下文"
        )
    }

    func testShellCommandRunSkillExecutesInAgentLoop() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let runtime = MagicianAgentRuntimeV3(
            providerSettingsStore: fixture.providerSettingsStore,
            rewriteProviderRegistry: RewriteProviderRegistry(providers: []),
            textOutputCoordinator: fixture.textOutputCoordinator,
            skillRuleStore: fixture.skillRuleStore,
            toolExecutor: ScenarioToolExecutor(),
            llmProvider: ScenarioTextGenerationProvider()
        )

        let request = MagicianAgentRequest(
            traceID: "scenario-shell-1",
            command: "统计 Magician Swift 文件数量并输出",
            selectionSnapshot: nil,
            focusContext: FocusedAppContext(
                appName: "Terminal",
                bundleID: "com.apple.Terminal",
                focusedRole: nil,
                hasEditableTarget: true,
                strategyHint: "test"
            ),
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        let outcome = try await runtime.run(request: request, onEvent: nil)
        XCTAssertEqual(outcome.finalStatusMessage, "全部步骤已完成")
        XCTAssertTrue(
            outcome.steps.contains(where: { $0.userMessage.contains("终端命令已执行") }),
            "应包含 shell.command.run 的执行步骤"
        )
        XCTAssertTrue(
            (outcome.finalOutputText ?? "").contains(where: { $0.isNumber }),
            "shell 命令输出应包含统计数字"
        )
    }

    func testMusicPlayQueryFailsWhenTrackEvidenceMissing() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let runtime = MagicianAgentRuntimeV3(
            providerSettingsStore: fixture.providerSettingsStore,
            rewriteProviderRegistry: RewriteProviderRegistry(providers: []),
            textOutputCoordinator: fixture.textOutputCoordinator,
            skillRuleStore: fixture.skillRuleStore,
            toolExecutor: MusicFallbackToolExecutor(),
            llmProvider: ScenarioTextGenerationProvider()
        )

        let request = MagicianAgentRequest(
            traceID: "scenario-music-evidence-missing",
            command: "播放稻香",
            selectionSnapshot: nil,
            focusContext: FocusedAppContext(
                appName: "TextEdit",
                bundleID: "com.apple.TextEdit",
                focusedRole: "AXTextArea",
                hasEditableTarget: true,
                strategyHint: "test"
            ),
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        do {
            _ = try await runtime.run(request: request, onEvent: nil)
            XCTFail("expected missing music track evidence to fail verification")
        } catch let error as MagicianError {
            XCTAssertEqual(error.code, .toolExecutionFailed)
            XCTAssertTrue(error.userMessage.contains("曲目证据"))
            XCTAssertTrue((error.debugMessage ?? "").contains("apple.music.play_query"))
        }
    }

    private func makeFixture() throws -> ScenarioFixture {
        let suiteName = "MagicianAgentRuntimeScenarioTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "MagicianAgentRuntimeScenarioTests", code: 1)
        }
        defaults.removePersistentDomain(forName: suiteName)
        let credentialStore = MemoryCredentialStoreForScenarioTests(
            storage: [
                defaultTextCredentialKeyRef: "sk-test-text",
                defaultCLITextCredentialKeyRef: "sk-test-cli"
            ]
        )
        let providerSettingsStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: credentialStore
        )
        providerSettingsStore.updateTextProviderType(.openAI)
        providerSettingsStore.updateCLITextProviderType(.openAI)

        let skillRuleStore = SkillRuleStore(
            defaults: defaults,
            storageKey: "skill.rules.magician.scenario.tests"
        )

        return ScenarioFixture(
            providerSettingsStore: providerSettingsStore,
            textOutputCoordinator: DummyTextOutputCoordinator(),
            skillRuleStore: skillRuleStore,
            cleanUp: {
                defaults.removePersistentDomain(forName: suiteName)
            }
        )
    }
}

private struct ScenarioFixture {
    let providerSettingsStore: ProviderSettingsStore
    let textOutputCoordinator: DummyTextOutputCoordinator
    let skillRuleStore: SkillRuleStore
    let cleanUp: () -> Void
}

private final class MemoryCredentialStoreForScenarioTests: ProviderCredentialStore {
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
        _ = allowUserInteraction
        return storage[profileID]?.isEmpty == false
    }
}

@MainActor
private final class DummyTextOutputCoordinator: TextOutputCoordinator {
    let insertionStrategy: String = "dummy"

    func currentSelectionSnapshot() -> FocusedSelectionSnapshot? {
        nil
    }

    func captureSelectionSnapshot() async -> FocusedSelectionSnapshot? {
        nil
    }

    func write(request: TextOutputRequest) async throws -> TextOutputResult {
        TextOutputResult(
            appName: request.focusContext.appName,
            bundleID: request.focusContext.bundleID,
            path: .accessibilitySelectionReplacement,
            usedFallback: false,
            didInsertIntoEditor: true,
            operation: request.operation
        )
    }
}

private final class ScenarioTextGenerationProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAI, .openAICompatible]
    private var stepsByGoal: [String: Int] = [:]

    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> TextGenerationResult {
        _ = configuration
        _ = apiKey

        let systemPrompt = request.systemPrompt
        let output: String
        if systemPrompt.contains("命令预处理模型") {
            let raw = section("raw_command", in: request.userPrompt)
            output = #"{"command":"\#(escape(raw))"}"#
        } else if systemPrompt.contains("意图规划模型") {
            let command = section("command", in: request.userPrompt)
            let plan = makePlan(for: command)
            stepsByGoal[plan.goal] = plan.stepsCount
            output = plan.json
        } else if systemPrompt.contains("skill router") {
            output = #"{"skills":[]}"#
        } else if systemPrompt.contains("核心推理执行器") {
            output = reasonOutput(for: request.userPrompt)
        } else if systemPrompt.contains("负责基于步骤证据判断是否继续执行") {
            let goal = section("goal", in: request.userPrompt)
            let index = Int(section("current_step_index", in: request.userPrompt)) ?? 1
            let total = stepsByGoal[goal] ?? 1
            if index >= total {
                output = #"{"decision":"done","final_message":"全部步骤已完成","append_step":null}"#
            } else {
                output = #"{"decision":"continue","final_message":"继续下一步","append_step":null}"#
            }
        } else {
            output = "OK"
        }

        return TextGenerationResult(
            providerType: .openAI,
            providerName: "ScenarioFake",
            modelName: "scenario-fake-model",
            outputText: output
        )
    }

    private func makePlan(for command: String) -> (goal: String, stepsCount: Int, json: String) {
        if command.contains("统计 Magician Swift 文件数量") {
            return (
                goal: "统计文件数量",
                stepsCount: 1,
                json: """
                {"goal":"统计文件数量","todo":[{"id":"1","text":"执行终端统计命令","status":"pending"}],"steps":[{"id":"step-1","objective":"统计 Magician Swift 文件数量","skill_id":"shell.command.run","input":{"command":"rg --files Sources/Core/Magician | wc -l"}}]}
                """
            )
        }
        if command.contains("播放稻香") {
            return (
                goal: "播放稻香",
                stepsCount: 1,
                json: """
                {"goal":"播放稻香","todo":[{"id":"1","text":"播放歌曲","status":"pending"}],"steps":[{"id":"step-1","objective":"播放稻香","skill_id":"apple.music.play_query","input":{"query":"稻香"}}]}
                """
            )
        }
        if command.contains("播放跨时代") {
            return (
                goal: "播放跨时代",
                stepsCount: 1,
                json: """
                {"goal":"播放跨时代","todo":[{"id":"1","text":"播放歌曲","status":"pending"}],"steps":[{"id":"step-1","objective":"播放跨时代","skill_id":"apple.music.play_query","input":{"query":"跨时代"}}]}
                """
            )
        }
        if command.contains("短篇小说") && command.contains("邮件") {
            return (
                goal: "写小说并写进邮件",
                stepsCount: 2,
                json: """
                {"goal":"写小说并写进邮件","todo":[{"id":"1","text":"生成短篇小说","status":"pending"},{"id":"2","text":"写入邮件草稿","status":"pending"}],"steps":[{"id":"step-1","objective":"写一篇短篇小说","skill_id":"core.reason.respond","input":{"instruction":"写一篇短篇小说，约300字"}},{"id":"step-2","objective":"把小说写进邮件","skill_id":"apple.mail.compose","input":{"subject":"短篇小说草稿"}}]}
                """
            )
        }
        if command.contains("翻译成日语") && command.contains("飞书") {
            return (
                goal: "翻译并写飞书日程",
                stepsCount: 2,
                json: """
                {"goal":"翻译并写飞书日程","todo":[{"id":"1","text":"翻译文本","status":"pending"},{"id":"2","text":"写入飞书日程","status":"pending"}],"steps":[{"id":"step-1","objective":"翻译成日语","skill_id":"core.reason.respond","input":{"instruction":"把选中文本翻译成日语"}},{"id":"step-2","objective":"写入飞书日程","skill_id":"feishu_calendar_event","input":{"spoken_command":"在飞书创建日程并写入日语内容"}}]}
                """
            )
        }
        if command.contains("七言绝句") {
            return (
                goal: "七言绝句总结",
                stepsCount: 1,
                json: """
                {"goal":"七言绝句总结","todo":[{"id":"1","text":"写七言绝句","status":"pending"}],"steps":[{"id":"step-1","objective":"把新闻总结为七言绝句","skill_id":"core.reason.respond","input":{"instruction":"请用一首七言绝句总结上述新闻"}}]}
                """
            )
        }
        if command.contains("飞书助手") && command.contains("消息") {
            return (
                goal: "给飞书助手发消息",
                stepsCount: 1,
                json: """
                {"goal":"给飞书助手发消息","todo":[{"id":"1","text":"发送飞书消息","status":"pending"}],"steps":[{"id":"step-1","objective":"发送飞书消息","skill_id":"feishu_im_user_message","input":{"arguments":["--text","这条消息来自 PulseType，很高兴认识你。"]}}]}
                """
            )
        }
        if command.contains("进出口") && command.contains("邮件") {
            return (
                goal: "调研进出口并写邮件",
                stepsCount: 2,
                json: """
                {"goal":"调研进出口并写邮件","todo":[{"id":"1","text":"调研并整理要点","status":"pending"},{"id":"2","text":"写成邮件草稿","status":"pending"}],"steps":[{"id":"step-1","objective":"整理2025年上半年中国进出口情况","skill_id":"core.reason.respond","input":{"instruction":"整理2025年上半年中国进出口的关键数据和结论"}},{"id":"step-2","objective":"写成新邮件","skill_id":"apple.mail.compose","input":{"subject":"2025年上半年中国进出口简报"}}]}
                """
            )
        }
        return (
            goal: command,
            stepsCount: 1,
            json: """
            {"goal":"\(escape(command))","todo":[{"id":"1","text":"处理请求","status":"pending"}],"steps":[{"id":"step-1","objective":"处理请求","skill_id":"core.reason.respond","input":{"instruction":"\(escape(command))"}}]}
            """
        )
    }

    private func reasonOutput(for userPrompt: String) -> String {
        let instruction = section("instruction", in: userPrompt)
        if instruction.contains("短篇小说") {
            return """
            雨夜里的路灯像一封迟到的信，照着巷口那家旧书店。阿青推门时，风把门铃吹成了轻颤的琴音。柜台后，白发店主递来一本没有封面的薄册，只说：“你找的答案，在最后一页。”阿青翻到终章，却只看到一行字：请回到第一页。她怔住，再读开头，才发现第一段悄悄多了一句“谢谢你愿意再来一次”。那一刻她明白，人生并非一直向前，有些章节要在回望里才会被真正读懂。她合上书，雨也停了，巷子尽头亮起一盏新的灯。
            """
        }
        if instruction.contains("翻译成日语") {
            return """
            ByteDance 2026インターン採用説明会（深セン大学城会場）が開催されます。時間は3月30日19:00、会場は北京大学深セン大学院・国際会議センター（J棟）です。事業責任者と卒業生の共有、現場マッチング、面接直通カードの機会、さらに抽選ギフトもあります。申込リンク：https://xy.liepin.com/bytedance2026
            """
        }
        if instruction.contains("七言绝句") {
            return """
            九域风云一纸笺
            边关海市起狼烟
            新规冷照人间事
            夜雨敲窗问太平
            """
        }
        if instruction.contains("进出口") {
            return """
            主题：2025年上半年中国进出口情况简报

            1) 总体规模保持韧性，出口结构继续向机电与高附加值产品集中。  
            2) 对东盟与共建“一带一路”市场保持较高活跃度，区域市场多元化趋势延续。  
            3) 进口端在能源与关键工业原材料上保持稳定，部分消费品与高端设备需求回升。  
            4) 建议：继续关注外需波动、运价变化与汇率区间，并提前布局重点行业订单节奏。
            """
        }
        return "已完成文本处理。"
    }

    private func section(_ key: String, in text: String) -> String {
        let marker = "\(key):\n"
        guard let range = text.range(of: marker) else {
            return ""
        }
        let tail = text[range.upperBound...]
        if let next = tail.range(of: "\n\n") {
            return String(tail[..<next.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

@MainActor
private final class ScenarioToolExecutor: MagicianToolExecuting {
    struct CallRecord {
        let intent: MagicianIntent
        let context: MagicianExecutionContext
    }

    private(set) var calls: [CallRecord] = []

    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) async throws -> MagicianExecutionResult {
        calls.append(CallRecord(intent: intent, context: context))

        switch intent.intent {
        case .controlMusic:
            let song: String
            if context.command.contains("稻香") {
                song = "稻香"
            } else if context.command.contains("跨时代") {
                song = "跨时代"
            } else {
                song = "目标歌曲"
            }
            let message = "已执行播放：\(song)"
            let trackEvidence = "track=\(song)|artist=周杰伦"
            return MagicianExecutionResult(
                intent: .controlMusic,
                userMessage: message,
                outputText: trackEvidence,
                historyDisplayText: message,
                fallbackUsed: false,
                observation: MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: song,
                    evidenceSummary: trackEvidence
                )
            )
        case .composeEmailDraft:
            let subject = intent.params.mailSubject ?? "未命名主题"
            let body = intent.params.mailBody ?? ""
            let output = "subject: \(subject)\nbody: \(body)"
            return MagicianExecutionResult(
                intent: .composeEmailDraft,
                userMessage: "邮件草稿已生成",
                outputText: output,
                historyDisplayText: "邮件草稿：\(subject)",
                fallbackUsed: false,
                observation: MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: subject,
                    evidenceSummary: "mail.compose"
                )
            )
        case .feishuCLI:
            let operation = intent.params.cliOperation ?? "unknown"
            let message: String
            if operation == FeishuCanonicalOperation.calendarEvent.rawValue {
                message = "飞书日程已创建"
            } else if operation == FeishuCanonicalOperation.imUserMessage.rawValue {
                message = "飞书消息已发送"
            } else {
                message = "飞书动作已执行"
            }
            return MagicianExecutionResult(
                intent: .feishuCLI,
                userMessage: message,
                outputText: "op=\(operation)\ncommand=\(context.command)",
                historyDisplayText: message,
                fallbackUsed: false,
                observation: MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: operation,
                    evidenceSummary: operation
                )
            )
        case .createEvent:
            return MagicianExecutionResult(
                intent: .createEvent,
                userMessage: "日程已创建",
                outputText: nil,
                historyDisplayText: "日程已创建",
                fallbackUsed: false,
                observation: MagicianAgentObservation(verificationStatus: .verified)
            )
        case .createNote:
            return MagicianExecutionResult(
                intent: .createNote,
                userMessage: "备忘录已创建",
                outputText: nil,
                historyDisplayText: "备忘录已创建",
                fallbackUsed: false,
                observation: MagicianAgentObservation(verificationStatus: .verified)
            )
        case .textTransform:
            return MagicianExecutionResult(
                intent: .textTransform,
                userMessage: "文本已处理",
                outputText: context.command,
                historyDisplayText: "文本已处理",
                fallbackUsed: false,
                observation: MagicianAgentObservation(verificationStatus: .verified)
            )
        }
    }
}

@MainActor
private final class MusicFallbackToolExecutor: MagicianToolExecuting {
    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) async throws -> MagicianExecutionResult {
        _ = context
        if intent.intent == .controlMusic {
            return MagicianExecutionResult(
                intent: .controlMusic,
                userMessage: "已开始播放：稻香",
                outputText: "state=play_fallback",
                historyDisplayText: "已开始播放：稻香",
                fallbackUsed: true,
                observation: MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: "稻香",
                    evidenceSummary: "state=play_fallback"
                )
            )
        }

        return MagicianExecutionResult(
            intent: intent.intent,
            userMessage: "OK",
            outputText: "OK",
            historyDisplayText: "OK",
            fallbackUsed: false,
            observation: MagicianAgentObservation(verificationStatus: .verified)
        )
    }
}

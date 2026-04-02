import XCTest
@testable import PulseType

final class V4PlannerLLMTests: XCTestCase {
    func testPlannerUsesModelForSimpleMusicIntent() async throws {
        let provider = TrackingPlannerGenerationProvider(
            output: #"{"action":"step","channel":"music","step":{"toolName":"apple.music.control","title":"控制音乐","inputSummary":"放首稻香"}}"#
        )
        let planner = V4PlannerLLM(
            generationProvider: provider,
            modelResolver: { _ in
                V4PlannerLLM.ModelContext(
                    configuration: TextGenerationProviderConfiguration(
                        profileID: "planner",
                        providerType: .openAICompatible,
                        providerName: "Stub",
                        modelName: "stub-model",
                        baseURL: URL(string: "https://example.com")!
                    ),
                    apiKey: "test-key"
                )
            }
        )

        let request = V4RunRequest(
            lane: .selectionRewrite,
            goalSummary: "放首稻香",
            inputText: "放首稻香"
        )

        let plan = try await planner.plan(for: request)

        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.toolName, "apple.music.control")
        let invocationCount = await provider.invocationCount
        XCTAssertEqual(invocationCount, 1)
    }

    func testPlannerUsesModelForTransformThenMailHandoff() async throws {
        let provider = TrackingPlannerGenerationProvider(
            output: #"{"action":"step","channel":"mail","step":{"toolName":"apple.mail.compose","title":"整理邮件","inputSummary":"给产品组发邮件，正文使用上一轮整理结果"}}"#
        )
        let planner = V4PlannerLLM(
            generationProvider: provider,
            modelResolver: { _ in
                V4PlannerLLM.ModelContext(
                    configuration: TextGenerationProviderConfiguration(
                        profileID: "planner",
                        providerType: .openAICompatible,
                        providerName: "Stub",
                        modelName: "stub-model",
                        baseURL: URL(string: "https://example.com")!
                    ),
                    apiKey: "test-key"
                )
            }
        )

        let request = V4RunRequest(
            lane: .selectionRewrite,
            goalSummary: "帮我整理一下发邮件给产品组",
            inputText: "帮我整理一下发邮件给产品组",
            selectionText: "这里是会议纪要",
            stepRecords: [
                V4StepRecord(
                    traceID: V4TraceID(rawValue: "trace"),
                    lane: .selectionRewrite,
                    goalSummary: "帮我整理一下发邮件给产品组",
                    title: "文字处理",
                    status: .completed,
                    toolName: "text.transform",
                    inputSummary: "帮我整理一下",
                    outputSummary: "整理好的纪要"
                )
            ]
        )

        let plan = try await planner.plan(for: request)

        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.toolName, "apple.mail.compose")
        let invocationCount = await provider.invocationCount
        XCTAssertEqual(invocationCount, 1)
    }

    func testPlannerUsesModelToFinishSimpleTask() async throws {
        let provider = TrackingPlannerGenerationProvider(
            output: #"{"action":"finish","message":"已完成当前任务。"}"#
        )
        let planner = V4PlannerLLM(
            generationProvider: provider,
            modelResolver: { _ in
                V4PlannerLLM.ModelContext(
                    configuration: TextGenerationProviderConfiguration(
                        profileID: "planner",
                        providerType: .openAICompatible,
                        providerName: "Stub",
                        modelName: "stub-model",
                        baseURL: URL(string: "https://example.com")!
                    ),
                    apiKey: "test-key"
                )
            }
        )

        let request = V4RunRequest(
            lane: .selectionRewrite,
            goalSummary: "放首稻香",
            inputText: "放首稻香",
            stepRecords: [
                V4StepRecord(
                    traceID: V4TraceID(rawValue: "trace"),
                    lane: .selectionRewrite,
                    goalSummary: "放首稻香",
                    title: "控制音乐",
                    status: .completed,
                    toolName: "apple.music.control",
                    inputSummary: "放首稻香",
                    outputSummary: "已开始播放"
                )
            ]
        )

        let plan = try await planner.plan(for: request)

        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.terminalDecision?.action, .finish)
        let invocationCount = await provider.invocationCount
        XCTAssertEqual(invocationCount, 1)
    }

    func testPlannerUsesModelStepDecision() async throws {
        let planner = V4PlannerLLM(
            generationProvider: StubGenerationProvider(
                output: #"{"action":"step","step":{"toolName":"apple.mail.compose","title":"发送邮件","inputSummary":"给产品组发邮件，正文使用上一轮整理结果"}}"#
            ),
            modelResolver: { _ in
                V4PlannerLLM.ModelContext(
                    configuration: TextGenerationProviderConfiguration(
                        profileID: "planner",
                        providerType: .openAICompatible,
                        providerName: "Stub",
                        modelName: "stub-model",
                        baseURL: URL(string: "https://example.com")!
                    ),
                    apiKey: "test-key"
                )
            }
        )

        let request = V4RunRequest(
            lane: .selectionRewrite,
            goalSummary: "帮我整理一下然后发给产品组",
            inputText: "帮我整理一下然后发给产品组",
            selectionText: "这里是会议纪要",
            stepRecords: [
                V4StepRecord(
                    traceID: V4TraceID(rawValue: "trace"),
                    lane: .selectionRewrite,
                    goalSummary: "帮我整理一下然后发给产品组",
                    title: "文字处理",
                    status: .completed,
                    toolName: "text.transform",
                    inputSummary: "帮我整理一下",
                    outputSummary: "整理好的纪要"
                )
            ]
        )

        let plan = try await planner.plan(for: request)

        XCTAssertEqual(plan.terminalDecision, nil)
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.toolName, "apple.mail.compose")
        XCTAssertEqual(plan.steps.first?.title, "发送邮件")
    }

    func testPlannerCanFinishFromModelDecision() async throws {
        let planner = V4PlannerLLM(
            generationProvider: StubGenerationProvider(
                output: #"{"action":"finish","message":"邮件已经发出，无需下一步。"}"#
            ),
            modelResolver: { _ in
                V4PlannerLLM.ModelContext(
                    configuration: TextGenerationProviderConfiguration(
                        profileID: "planner",
                        providerType: .openAICompatible,
                        providerName: "Stub",
                        modelName: "stub-model",
                        baseURL: URL(string: "https://example.com")!
                    ),
                    apiKey: "test-key"
                )
            }
        )

        let request = V4RunRequest(
            lane: .selectionRewrite,
            goalSummary: "先整理一下，然后给产品组发邮件",
            inputText: "先整理一下，然后给产品组发邮件",
            stepRecords: [
                V4StepRecord(
                    traceID: V4TraceID(rawValue: "trace"),
                    lane: .selectionRewrite,
                    goalSummary: "先整理一下，然后给产品组发邮件",
                    title: "文字处理",
                    status: .completed,
                    toolName: "text.transform",
                    inputSummary: "先整理一下",
                    outputSummary: "整理好的纪要"
                ),
                V4StepRecord(
                    traceID: V4TraceID(rawValue: "trace"),
                    lane: .selectionRewrite,
                    goalSummary: "先整理一下，然后给产品组发邮件",
                    title: "整理邮件",
                    status: .completed,
                    toolName: "apple.mail.compose",
                    inputSummary: "给产品组发邮件",
                    outputSummary: "邮件已发出"
                )
            ]
        )

        let plan = try await planner.plan(for: request)

        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.terminalDecision?.action, .finish)
        XCTAssertEqual(plan.terminalDecision?.message, "邮件已经发出，无需下一步。")
    }

    func testPlannerFallsBackWhenModelOutputInvalid() async throws {
        let planner = V4PlannerLLM(
            generationProvider: StubGenerationProvider(output: "not-json"),
            modelResolver: { _ in
                V4PlannerLLM.ModelContext(
                    configuration: TextGenerationProviderConfiguration(
                        profileID: "planner",
                        providerType: .openAICompatible,
                        providerName: "Stub",
                        modelName: "stub-model",
                        baseURL: URL(string: "https://example.com")!
                    ),
                    apiKey: "test-key"
                )
            }
        )

        let request = V4RunRequest(
            lane: .selectionRewrite,
            goalSummary: "先润色这段文字，然后写进备忘录",
            inputText: "先润色这段文字，然后写进备忘录",
            selectionText: "原始选中文本"
        )

        let plan = try await planner.plan(for: request)

        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.toolName, "text.transform")
    }

    func testPlannerFallsBackWhenModelUnavailableForResearchThenNotesFlow() async throws {
        let provider = TrackingPlannerGenerationProvider(output: #"{"action":"fail","message":"unused"}"#)
        let planner = V4PlannerLLM(
            generationProvider: provider,
            modelResolver: { _ in nil }
        )

        let firstPlan = try await planner.plan(
            for: V4RunRequest(
                lane: .selectionRewrite,
                goalSummary: "调研并写进备忘录",
                inputText: "请调研一下本周 AI 产品趋势，写一篇短文放到备忘录"
            )
        )
        XCTAssertEqual(firstPlan.steps.count, 1)
        XCTAssertNotEqual(firstPlan.steps.first?.toolName, "apple.notes.create")

        let secondPlan = try await planner.plan(
            for: V4RunRequest(
                lane: .selectionRewrite,
                goalSummary: "调研并写进备忘录",
                inputText: "请调研一下本周 AI 产品趋势，写一篇短文放到备忘录",
                stepRecords: [
                    V4StepRecord(
                        traceID: V4TraceID(rawValue: "trace"),
                        lane: .selectionRewrite,
                        goalSummary: "调研并写进备忘录",
                        title: "文字处理",
                        status: .completed,
                        toolName: "text.transform",
                        inputSummary: "调研并整理",
                        outputSummary: "这是整理好的短文"
                    )
                ]
            )
        )
        XCTAssertTrue(secondPlan.steps.isEmpty)
        XCTAssertEqual(secondPlan.terminalDecision?.action, .finish)

        let invocationCount = await provider.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    func testPlannerFallsBackWhenModelUnavailableForWriteIntoDocumentFlow() async throws {
        let provider = TrackingPlannerGenerationProvider(output: #"{"action":"fail","message":"unused"}"#)
        let planner = V4PlannerLLM(
            generationProvider: provider,
            modelResolver: { _ in nil }
        )

        let command = "二零一五年中国上半年经济情况，并写进文档。"
        let firstPlan = try await planner.plan(
            for: V4RunRequest(
                lane: .selectionRewrite,
                goalSummary: command,
                inputText: command
            )
        )
        XCTAssertEqual(firstPlan.steps.count, 1)
        XCTAssertEqual(firstPlan.steps.first?.toolName, "text.transform")

        let secondPlan = try await planner.plan(
            for: V4RunRequest(
                lane: .selectionRewrite,
                goalSummary: command,
                inputText: command,
                stepRecords: [
                    V4StepRecord(
                        traceID: V4TraceID(rawValue: "trace"),
                        lane: .selectionRewrite,
                        goalSummary: command,
                        title: "文字处理",
                        status: .completed,
                        toolName: "text.transform",
                        inputSummary: "调研并整理",
                        outputSummary: "这是整理好的文章"
                    )
                ]
            )
        )
        XCTAssertTrue(secondPlan.steps.isEmpty)
        XCTAssertEqual(secondPlan.terminalDecision?.action, .finish)

        let invocationCount = await provider.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    func testPlannerMapsLowSignalSkillWithSelectionToTextTransformWhenModelUnavailable() async throws {
        let provider = TrackingPlannerGenerationProvider(output: #"{"action":"fail","message":"unused"}"#)
        let planner = V4PlannerLLM(
            generationProvider: provider,
            modelResolver: { _ in nil }
        )

        let plan = try await planner.plan(
            for: V4RunRequest(
                lane: .selectionRewrite,
                goalSummary: "写进备忘录",
                inputText: "skill",
                selectionText: "这是用户选中的一段文本"
            )
        )

        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.toolName, "text.transform")
        let invocationCount = await provider.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    func testPlannerDoesNotAskForSelectionWhenTranslateToNotesWithoutSelection() async throws {
        let provider = TrackingPlannerGenerationProvider(output: #"{"action":"fail","message":"unused"}"#)
        let planner = V4PlannerLLM(
            generationProvider: provider,
            modelResolver: { _ in nil }
        )

        let plan = try await planner.plan(
            for: V4RunRequest(
                lane: .selectionRewrite,
                goalSummary: "翻译并写备忘录",
                inputText: "翻译成中文，并写入备忘录。"
            )
        )

        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.toolName, "text.transform")
        let invocationCount = await provider.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }
}

private struct StubGenerationProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAI, .openAICompatible]
    let output: String

    func generateText(
        request _: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey _: String
    ) async throws -> TextGenerationResult {
        TextGenerationResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            outputText: output
        )
    }
}

private actor TrackingPlannerGenerationProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAI, .openAICompatible]

    private(set) var invocationCount = 0
    private let output: String

    init(output: String) {
        self.output = output
    }

    func generateText(
        request _: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey _: String
    ) async throws -> TextGenerationResult {
        invocationCount += 1
        return TextGenerationResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            outputText: output
        )
    }
}

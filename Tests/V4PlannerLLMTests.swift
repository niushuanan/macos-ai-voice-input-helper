import XCTest
@testable import PulseType

final class V4PlannerLLMTests: XCTestCase {
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
            goalSummary: "给产品组发邮件",
            inputText: "给产品组发邮件",
            stepRecords: [
                V4StepRecord(
                    traceID: V4TraceID(rawValue: "trace"),
                    lane: .selectionRewrite,
                    goalSummary: "给产品组发邮件",
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

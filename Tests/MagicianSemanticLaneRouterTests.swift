import XCTest
@testable import PulseType

final class MagicianSemanticLaneRouterTests: XCTestCase {
    func testSemanticRouterUsesLLMDecisionWhenAvailable() async {
        let provider = TrackingLaneGenerationProvider(
            output: #"{"lane":"agent","reason":"semantic_feishu_workflow"}"#
        )
        let router = MagicianSemanticLaneRouter(
            generationProvider: provider,
            modelResolver: {
                MagicianSemanticLaneRouter.ModelContext(
                    configuration: TextGenerationProviderConfiguration(
                        profileID: "lane-router",
                        providerType: .openAICompatible,
                        providerName: "Stub",
                        modelName: "stub-model",
                        baseURL: URL(string: "https://example.com")!
                    ),
                    apiKey: "test-key"
                )
            }
        )

        let decision = await router.decide(
            command: "把这段内容发到飞书群里",
            selectionSnapshot: nil,
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .agent)
        XCTAssertEqual(decision.reason, "semantic_feishu_workflow")
        let calls = await provider.invocationCount
        XCTAssertEqual(calls, 1)
    }

    func testSemanticRouterFallsBackWhenModelOutputInvalid() async {
        let provider = TrackingLaneGenerationProvider(output: "invalid json")
        let router = MagicianSemanticLaneRouter(
            generationProvider: provider,
            modelResolver: {
                MagicianSemanticLaneRouter.ModelContext(
                    configuration: TextGenerationProviderConfiguration(
                        profileID: "lane-router",
                        providerType: .openAICompatible,
                        providerName: "Stub",
                        modelName: "stub-model",
                        baseURL: URL(string: "https://example.com")!
                    ),
                    apiKey: "test-key"
                )
            }
        )

        let decision = await router.decide(
            command: "写进备忘录并发到飞书",
            selectionSnapshot: nil,
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .agent)
        XCTAssertEqual(decision.reason, "semantic_router_error")
        let calls = await provider.invocationCount
        XCTAssertEqual(calls, 1)
    }

    func testSemanticRouterUsesAgentDefaultWhenModelUnavailable() async {
        let provider = TrackingLaneGenerationProvider(
            output: #"{"lane":"native_fast","reason":"unused"}"#
        )
        let router = MagicianSemanticLaneRouter(
            generationProvider: provider,
            modelResolver: { nil }
        )

        let decision = await router.decide(
            command: "把这段话整理一下并写进备忘录",
            selectionSnapshot: nil,
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .agent)
        XCTAssertEqual(decision.reason, "semantic_router_no_model")
        XCTAssertEqual(decision.selectionMode, .optional)
        let calls = await provider.invocationCount
        XCTAssertEqual(calls, 0)
    }

    func testSemanticRouterParsesSelectionModeFromModelOutput() async {
        let provider = TrackingLaneGenerationProvider(
            output: #"{"lane":"agent","selection_mode":"none","reason":"music_command"}"#
        )
        let router = MagicianSemanticLaneRouter(
            generationProvider: provider,
            modelResolver: {
                MagicianSemanticLaneRouter.ModelContext(
                    configuration: TextGenerationProviderConfiguration(
                        profileID: "lane-router",
                        providerType: .openAICompatible,
                        providerName: "Stub",
                        modelName: "stub-model",
                        baseURL: URL(string: "https://example.com")!
                    ),
                    apiKey: "test-key"
                )
            }
        )

        let decision = await router.decide(
            command: "播放稻香",
            selectionSnapshot: FocusedSelectionSnapshot(
                focusContext: FocusedAppContext(
                    appName: "TextEdit",
                    bundleID: "com.apple.TextEdit",
                    focusedRole: "AXTextArea",
                    hasEditableTarget: true,
                    strategyHint: "test"
                ),
                selectedText: "旧选区"
            ),
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .agent)
        XCTAssertEqual(decision.selectionMode, .none)
    }
}

private actor TrackingLaneGenerationProvider: TextGenerationProvider {
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

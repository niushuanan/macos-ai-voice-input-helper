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
            output: #"{"lane":"agent","path":"music_fast","selection_mode":"none","normalized_intent":"play","normalized_query":"稻香","reason":"music_command"}"#
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
        XCTAssertEqual(decision.executionPath, .musicFast)
        XCTAssertEqual(decision.normalizedIntent, .play)
        XCTAssertEqual(decision.normalizedQuery, "稻香")
    }

    func testSemanticRouterForcesPlannerForLiveSelectionTransformCommands() async {
        let provider = TrackingLaneGenerationProvider(
            output: #"{"lane":"agent","path":"music_fast","selection_mode":"none","normalized_intent":"open","reason":"music_command"}"#
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
            command: "翻译成中文",
            selectionSnapshot: FocusedSelectionSnapshot(
                focusContext: FocusedAppContext(
                    appName: "TextEdit",
                    bundleID: "com.apple.TextEdit",
                    focusedRole: "AXTextArea",
                    hasEditableTarget: true,
                    strategyHint: "test"
                ),
                selectedText: "It boggles the mind."
            ),
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .agent)
        XCTAssertEqual(decision.reason, "semantic_selection_transform_guard")
        XCTAssertEqual(decision.selectionMode, .required)
        XCTAssertEqual(decision.executionPath, .plannerV4)
        XCTAssertNil(decision.normalizedIntent)
        XCTAssertNil(decision.normalizedQuery)
        let calls = await provider.invocationCount
        XCTAssertEqual(calls, 0)
    }

    func testSemanticRouterRejectsMusicFastWhenCommandDoesNotLookLikeMusic() async {
        let provider = TrackingLaneGenerationProvider(
            output: #"{"lane":"native_fast","path":"music_fast","selection_mode":"optional","normalized_intent":"open","reason":"music_command"}"#
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
            command: "帮我整理一下这段会议纪要",
            selectionSnapshot: nil,
            enabledFeatures: Set(MagicianFeatureID.allCases)
        )

        XCTAssertEqual(decision.lane, .agent)
        XCTAssertEqual(decision.reason, "semantic_music_guard")
        XCTAssertEqual(decision.selectionMode, .optional)
        XCTAssertEqual(decision.executionPath, .plannerV4)
        XCTAssertNil(decision.normalizedIntent)
        XCTAssertNil(decision.normalizedQuery)
        let calls = await provider.invocationCount
        XCTAssertEqual(calls, 1)
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

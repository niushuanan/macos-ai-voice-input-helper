import Foundation
import XCTest
@testable import PulseType

final class SemanticEditorTests: XCTestCase {
    func testFactGuardRejectsChangedNumbersEnglishTokensAndNegation() {
        let guardrail = SemanticFactGuard(
            source: "订单 AB-129 不要改成 130，发到 ops@example.com",
            dictionaryTerms: []
        )

        XCTAssertFalse(guardrail.accepts("订单 AB-128 要改成 130，发到 ops@example.com"))
        XCTAssertTrue(guardrail.accepts("订单 AB-129，不要改成 130，发到 ops@example.com。"))
    }

    func testFactGuardPreservesDictionaryTermsThatAppearInSource() {
        let guardrail = SemanticFactGuard(
            source: "请把 PulseType 的延迟降下来",
            dictionaryTerms: ["PulseType", "Typeless"]
        )

        XCTAssertFalse(guardrail.accepts("请把 Pulse Time 的延迟降下来。"))
        XCTAssertTrue(guardrail.accepts("请把 PulseType 的延迟降下来。"))
    }

    func testEditorUsesConservativePromptAndAcceptsPunctuationOnlyCleanup() async {
        let provider = RecordingSemanticTextProvider(output: "订单 AB-129，不要改成 130。")
        let editor = SemanticEditor(provider: provider, editTimeout: 1)

        let result = await editor.edit(
            segmentID: "segment-1",
            revision: 1,
            source: "订单 AB-129 不要改成 130",
            context: fixtureContext(dictionaryTerms: ["AB-129"])
        )

        XCTAssertEqual(result.outputText, "订单 AB-129，不要改成 130。")
        XCTAssertEqual(result.disposition, .accepted)
        let request = await provider.lastRequest
        XCTAssertTrue(request?.systemPrompt.contains("不得回答") == true)
        XCTAssertTrue(request?.systemPrompt.contains("不得执行") == true)
        XCTAssertTrue(request?.systemPrompt.contains("保留数字") == true)
    }

    func testOlderRevisionCannotReplaceNewerSegment() async {
        let provider = DelayedSemanticTextProvider()
        let editor = SemanticEditor(provider: provider, editTimeout: 1)

        let oldTask = Task {
            await editor.edit(
                segmentID: "segment-1",
                revision: 1,
                source: "旧文本",
                context: fixtureContext()
            )
        }
        try? await waitUntil {
            await provider.startedSources.contains("旧文本")
        }

        let newer = await editor.edit(
            segmentID: "segment-1",
            revision: 2,
            source: "新文本",
            context: fixtureContext()
        )
        let older = await oldTask.value

        XCTAssertEqual(newer.outputText, "新文本。")
        XCTAssertEqual(newer.disposition, .accepted)
        XCTAssertEqual(older.outputText, "旧文本")
        XCTAssertEqual(older.disposition, .staleRevision)
        let olderIsCurrent = await editor.isCurrent(older)
        let newerIsCurrent = await editor.isCurrent(newer)
        XCTAssertFalse(olderIsCurrent)
        XCTAssertTrue(newerIsCurrent)
    }

    func testEditorCapsConcurrentProviderCallsAtTwo() async {
        let provider = ConcurrencyTrackingSemanticTextProvider()
        let editor = SemanticEditor(provider: provider, maximumConcurrentEdits: 2, editTimeout: 1)

        await withTaskGroup(of: SemanticEditResult.self) { group in
            for index in 0..<5 {
                group.addTask {
                    await editor.edit(
                        segmentID: "segment-\(index)",
                        revision: 1,
                        source: "文本\(index)",
                        context: self.fixtureContext()
                    )
                }
            }
            for await _ in group {}
        }

        let maximumInFlight = await provider.maximumInFlight
        XCTAssertEqual(maximumInFlight, 2)
    }

    func testProviderFailureFallsBackToSourceText() async {
        let editor = SemanticEditor(provider: FailingSemanticTextProvider(), editTimeout: 1)

        let result = await editor.edit(
            segmentID: "segment-1",
            revision: 1,
            source: "保持原文",
            context: fixtureContext()
        )

        XCTAssertEqual(result.outputText, "保持原文")
        XCTAssertEqual(result.disposition, .providerFallback)
    }

    private func fixtureContext(dictionaryTerms: [String] = []) -> SemanticEditorContext {
        SemanticEditorContext(
            configuration: TextGenerationProviderConfiguration(
                profileID: "text-primary",
                providerType: .openAICompatible,
                providerName: "Test",
                modelName: "test-model",
                baseURL: URL(string: "https://example.com/v1")!
            ),
            apiKey: "test-key",
            appName: "Codex",
            bundleID: "com.openai.codex",
            appPrompt: nil,
            userSystemPrompt: nil,
            dictionaryTerms: dictionaryTerms
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition was not met before timeout")
    }
}

private actor RecordingSemanticTextProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAICompatible]
    private let output: String
    private(set) var lastRequest: TextGenerationRequest?

    init(output: String) {
        self.output = output
    }

    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> TextGenerationResult {
        lastRequest = request
        return TextGenerationResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            outputText: output
        )
    }
}

private actor DelayedSemanticTextProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAICompatible]
    private(set) var startedSources: [String] = []

    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> TextGenerationResult {
        let source = request.userPrompt.contains("旧文本") ? "旧文本" : "新文本"
        startedSources.append(source)
        if source == "旧文本" {
            try await Task.sleep(nanoseconds: 80_000_000)
        } else {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return TextGenerationResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            outputText: "\(source)。"
        )
    }
}

private actor ConcurrencyTrackingSemanticTextProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAICompatible]
    private var inFlight = 0
    private(set) var maximumInFlight = 0

    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> TextGenerationResult {
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        try await Task.sleep(nanoseconds: 30_000_000)
        inFlight -= 1
        let source = request.userPrompt
            .components(separatedBy: "<<<TEXT\n").last?
            .components(separatedBy: "\nTEXT>>>").first ?? ""
        return TextGenerationResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            outputText: source
        )
    }
}

private struct FailingSemanticTextProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAICompatible]

    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> TextGenerationResult {
        throw URLError(.notConnectedToInternet)
    }
}

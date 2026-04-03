import Foundation
import XCTest
@testable import PulseType

final class V4MDPipelineToolTests: XCTestCase {
    func testInputMatrixRejectsAllEmpty() async {
        let tool = makeTool(output: "{}")
        let failure = await tool.validateSemanticInput(
            arguments: ["command": .string("   ")],
            context: makeContext(inputText: "", selectionText: nil)
        )
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.code, .invalidRequest)
    }

    func testInputMatrixAcceptsSevenValidCombinations() async {
        let tool = makeTool(output: "{}")

        let fileArgs: V4ToolArguments = [
            "selectedFiles": .array([
                .object([
                    "path": .string("/tmp/demo.pdf"),
                    "name": .string("demo.pdf"),
                    "type": .string("pdf")
                ])
            ])
        ]

        // 1) 仅语音
        let onlyVoice = await tool.validateSemanticInput(
            arguments: ["command": .string("生成会议纪要")],
            context: makeContext(inputText: "", selectionText: nil)
        )
        XCTAssertNil(onlyVoice)
        // 2) 仅选区
        let onlySelection = await tool.validateSemanticInput(
            arguments: [:],
            context: makeContext(inputText: "", selectionText: "这是选中内容")
        )
        XCTAssertNil(onlySelection)
        // 3) 仅文件
        let onlyFiles = await tool.validateSemanticInput(
            arguments: fileArgs,
            context: makeContext(inputText: "", selectionText: nil)
        )
        XCTAssertNil(onlyFiles)
        // 4) 语音 + 选区
        let voiceAndSelection = await tool.validateSemanticInput(
            arguments: ["command": .string("整理成周报")],
            context: makeContext(inputText: "", selectionText: "选区")
        )
        XCTAssertNil(voiceAndSelection)
        // 5) 语音 + 文件
        let voiceAndFiles = await tool.validateSemanticInput(
            arguments: ["command": .string("整理成周报"), "selectedFiles": fileArgs["selectedFiles"]!],
            context: makeContext(inputText: "", selectionText: nil)
        )
        XCTAssertNil(voiceAndFiles)
        // 6) 选区 + 文件
        let selectionAndFiles = await tool.validateSemanticInput(
            arguments: fileArgs,
            context: makeContext(inputText: "", selectionText: "选区")
        )
        XCTAssertNil(selectionAndFiles)
        // 7) 语音 + 选区 + 文件
        let allSources = await tool.validateSemanticInput(
            arguments: ["command": .string("整理"), "selectedFiles": fileArgs["selectedFiles"]!],
            context: makeContext(inputText: "", selectionText: "选区")
        )
        XCTAssertNil(allSources)
    }

    func testMDPipelineWritesMarkdownFile() async throws {
        let json = #"{"title":"项目周报","summary":["本周完成核心重构"],"key_points":["统一 PromptEnvelope"],"action_items":[{"owner":"产品","deadline":"下周三","task":"评审发布"}],"risks":["回归风险"],"todo":["补齐测试"],"references":[],"source_anchors":[]}"#
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsetype-v4-md-pipeline-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let tool = makeTool(output: json, fileManager: .default)
        let output = try await tool.execute(
            arguments: [
                "command": .string("生成周报"),
                "networkPolicy": .string("off"),
                "styleProfile": .string("weekly_report")
            ],
            context: makeContext()
        )

        XCTAssertTrue(output.evidenceSummary.contains("md.pipeline path="))
        guard case let .object(payload)? = output.rawPayload,
              let path = payload["path"]?.stringValue else {
            XCTFail("payload missing path")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let content = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        XCTAssertTrue(content.contains("# 项目周报"))
        XCTAssertTrue(content.contains("## 关键点"))
        XCTAssertTrue(content.contains("统一 PromptEnvelope"))
        guard case let .object(payload)? = output.rawPayload,
              let badges = payload["inputSourceBadges"]?.arrayValue?.compactMap(\.stringValue) else {
            XCTFail("payload missing inputSourceBadges")
            return
        }
        XCTAssertTrue(badges.contains("voice"))
        try? FileManager.default.removeItem(atPath: path)
    }

    private func makeTool(output: String, fileManager: FileManager = .default) -> V4MDPipelineTool {
        let modelContext = V4PlannerLLM.ModelContext(
            configuration: TextGenerationProviderConfiguration(
                profileID: "test",
                providerType: .openAICompatible,
                providerName: "test",
                modelName: "test-model",
                baseURL: URL(string: "https://example.com")!
            ),
            apiKey: "test-key"
        )
        return V4MDPipelineTool(
            modelContextOverride: modelContext,
            generationProvider: StubMDPipelineTextGenerationProvider(output: output),
            fileManager: fileManager
        )
    }

    private func makeContext(
        inputText: String = "测试",
        selectionText: String? = nil
    ) -> V4ToolExecutionContext {
        let request = V4RunRequest(
            lane: .selectionRewrite,
            goalSummary: "测试",
            inputText: inputText,
            selectionText: selectionText
        )
        let step = V4StepRecord(
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            title: "生成 Markdown 文档",
            status: .queued,
            toolName: "md.pipeline",
            inputSummary: "测试"
        )
        return V4ToolExecutionContext(
            toolUse: V4ToolUse(
                runID: request.runID,
                stepID: step.id,
                traceID: request.traceID,
                lane: request.lane,
                goalSummary: request.goalSummary,
                toolName: "md.pipeline",
                inputJSON: "{}",
                inputSummary: "测试",
                requestedAt: Date()
            ),
            request: request,
            step: step,
            accumulatedStepRecords: [],
            turnIndex: 1
        )
    }
}

private struct StubMDPipelineTextGenerationProvider: TextGenerationProvider {
    let supportedProviderTypes: [ProviderType] = [.openAICompatible]
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

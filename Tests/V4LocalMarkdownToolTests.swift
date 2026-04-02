import Foundation
import XCTest
@testable import PulseType

final class V4LocalMarkdownToolTests: XCTestCase {
    func testLocalMarkdownToolWritesFileIntoMDDirectory() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsetype-v4-md-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let tool = V4LocalMarkdownTool(baseDirectoryResolver: { tempRoot })
        let output = try await tool.execute(
            arguments: [
                "command": .string("总结这段文字"),
                "title": .string("测试标题"),
                "body": .string("这是处理后的正文。"),
                "sourceText": .string("这是原文。")
            ],
            context: makeContext()
        )

        XCTAssertTrue(output.evidenceSummary.contains("local.md.create file="))
        let mdFolder = tempRoot.appendingPathComponent("md", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: mdFolder,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        let content = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(content.contains("# 测试标题"))
        XCTAssertTrue(content.contains("## 原文"))
        XCTAssertTrue(content.contains("## 结果"))
        XCTAssertTrue(content.contains("这是处理后的正文。"))
    }

    func testLocalMarkdownToolRejectsEmptyBody() async {
        let tool = V4LocalMarkdownTool()
        let failure = await tool.validateSemanticInput(
            arguments: ["body": .string("   ")],
            context: makeContext()
        )
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.code, .toolValidationFailed)
    }

    func testLocalMarkdownToolDefaultResolverWritesIntoRepositoryMD() async throws {
        let tool = V4LocalMarkdownTool()
        let output = try await tool.execute(
            arguments: [
                "command": .string("默认总结"),
                "title": .string("真实路径测试"),
                "body": .string("这里是用于真实路径验证的正文。")
            ],
            context: makeContext()
        )

        guard
            case let .object(payload)? = output.rawPayload,
            let path = payload["path"]?.stringValue
        else {
            XCTFail("rawPayload 缺少 path")
            return
        }

        let fileURL = URL(fileURLWithPath: path)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertTrue(path.contains("/md/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("# 真实路径测试"))
        XCTAssertTrue(content.contains("## 结果"))
    }

    private func makeContext() -> V4ToolExecutionContext {
        let request = V4RunRequest(
            lane: .selectionRewrite,
            goalSummary: "测试",
            inputText: "测试"
        )
        let step = V4StepRecord(
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            title: "测试步骤",
            status: .queued,
            toolName: "local.md.create",
            inputSummary: "测试"
        )
        return V4ToolExecutionContext(
            toolUse: V4ToolUse(
                runID: request.runID,
                stepID: step.id,
                traceID: request.traceID,
                lane: request.lane,
                goalSummary: request.goalSummary,
                toolName: "local.md.create",
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

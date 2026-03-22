import XCTest
@testable import PulseType

@MainActor
final class LocalSenseVoiceRuntimeManagerTests: XCTestCase {
    func testValidateModelDirectoryAcceptsCompleteModel() throws {
        let modelDirectory = try makeModelDirectory()
        defer { try? FileManager.default.removeItem(at: modelDirectory) }

        XCTAssertNil(LocalSenseVoiceRuntimeManager.validateModelDirectory(rawPath: modelDirectory.path))
    }

    func testDetectReportsNotPreparedWhenRuntimePythonIsMissing() async throws {
        let modelDirectory = try makeModelDirectory()
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensevoice-runtime-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: modelDirectory)
            try? FileManager.default.removeItem(at: runtimeDirectory)
        }

        let manager = LocalSenseVoiceRuntimeManager(runtimeRoot: runtimeDirectory)
        await manager.detect(modelDirectoryPath: modelDirectory.path)

        guard case let .notPrepared(reason) = manager.state else {
            return XCTFail("Expected notPrepared state, got \(manager.state)")
        }
        XCTAssertTrue(reason.contains("准备"))
    }

    func testDetectReportsModelDirectoryError() async {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensevoice-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }

        let manager = LocalSenseVoiceRuntimeManager(runtimeRoot: runtimeDirectory)
        await manager.detect(modelDirectoryPath: "/tmp/pulsetype-model-missing-\(UUID().uuidString)")

        guard case let .failed(message) = manager.state else {
            return XCTFail("Expected failed state, got \(manager.state)")
        }
        XCTAssertTrue(message.contains("模型目录不存在"))
    }

    private func makeModelDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensevoice-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("onnx".utf8).write(to: directory.appendingPathComponent("model.onnx"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokens.json"))
        try Data("frontend: default".utf8).write(to: directory.appendingPathComponent("config.yaml"))
        return directory
    }
}

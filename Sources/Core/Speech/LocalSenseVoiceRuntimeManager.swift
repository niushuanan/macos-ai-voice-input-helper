import Foundation

struct LocalSenseVoiceRuntimeManifest: Codable, Equatable {
    let backend: String
    let pythonPath: String
    let packageVersions: [String: String]
    let preparedAt: Date
}

enum LocalSenseVoiceRuntimeState: Equatable {
    case unknown
    case checking
    case notPrepared(reason: String)
    case preparing(step: String)
    case ready(backend: String)
    case failed(message: String)
}

@MainActor
final class LocalSenseVoiceRuntimeManager: ObservableObject {
    @Published private(set) var state: LocalSenseVoiceRuntimeState = .unknown
    @Published private(set) var manifest: LocalSenseVoiceRuntimeManifest?
    @Published private(set) var lastCheckedAt: Date?

    let runtimeRoot: URL

    private let fileManager: FileManager
    private let now: () -> Date

    init(
        runtimeRoot: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.runtimeRoot = runtimeRoot
        self.fileManager = fileManager
        self.now = now
        self.manifest = Self.loadManifest(from: runtimeRoot)
    }

    var runtimeRootPath: String {
        runtimeRoot.path
    }

    var pythonPath: String {
        Self.managedPythonURL(runtimeRoot: runtimeRoot).path
    }

    nonisolated static func defaultRuntimeRoot(fileManager: FileManager = .default) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return baseDirectory
            .appendingPathComponent("PulseType", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("SenseVoice", isDirectory: true)
    }

    var currentStatusText: String {
        switch state {
        case .unknown:
            return "还没有检测本地运行环境。"
        case .checking:
            return "正在检测本地运行环境。"
        case let .notPrepared(reason):
            return reason
        case let .preparing(step):
            return step
        case let .ready(backend):
            return "本地运行环境已就绪，当前后端：\(backend)。"
        case let .failed(message):
            return message
        }
    }

    func detect(modelDirectoryPath: String?) async {
        state = .checking
        lastCheckedAt = now()

        if let validationError = Self.validateModelDirectory(rawPath: modelDirectoryPath, fileManager: fileManager) {
            state = .failed(message: validationError)
            manifest = Self.loadManifest(from: runtimeRoot)
            return
        }

        let pythonURL = Self.managedPythonURL(runtimeRoot: runtimeRoot)
        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            state = .notPrepared(reason: "本地运行环境还没准备，请先点“准备本地环境”。")
            manifest = Self.loadManifest(from: runtimeRoot)
            return
        }

        let result = Self.runProcess(
            executableURL: pythonURL,
            arguments: ["-c", Self.probeScript]
        )

        if result.exitCode != 0 {
            state = .failed(message: "本地运行环境检测失败：\(result.stderr.isEmpty ? result.stdout : result.stderr)")
            manifest = Self.loadManifest(from: runtimeRoot)
            return
        }

        guard
            let data = result.stdout.data(using: .utf8),
            let payload = try? JSONDecoder().decode(ProbePayload.self, from: data)
        else {
            state = .failed(message: "本地运行环境检测失败：返回内容无法解析。")
            manifest = Self.loadManifest(from: runtimeRoot)
            return
        }

        guard payload.ok else {
            state = .notPrepared(reason: payload.message)
            manifest = Self.loadManifest(from: runtimeRoot)
            return
        }

        let manifest = LocalSenseVoiceRuntimeManifest(
            backend: payload.backend,
            pythonPath: pythonURL.path,
            packageVersions: payload.versions,
            preparedAt: now()
        )
        Self.persistManifest(manifest, to: runtimeRoot, fileManager: fileManager)
        self.manifest = manifest
        state = .ready(backend: payload.backend)
    }

    func prepare(modelDirectoryPath: String?) async {
        if let validationError = Self.validateModelDirectory(rawPath: modelDirectoryPath, fileManager: fileManager) {
            state = .failed(message: validationError)
            lastCheckedAt = now()
            return
        }

        guard let preferredPython = Self.preferredPythonCommand(fileManager: fileManager) else {
            state = .failed(message: "没有找到可用的 Python 解释器。请先安装 Python 3.11。")
            lastCheckedAt = now()
            return
        }

        lastCheckedAt = now()
        state = .preparing(step: "正在创建本地 Python 环境（\(preferredPython.displayName)）…")
        do {
            try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        } catch {
            state = .failed(message: "无法创建本地运行目录：\(error.localizedDescription)")
            return
        }

        let venvDirectory = Self.venvDirectory(runtimeRoot: runtimeRoot)
        if Self.shouldRecreateEnvironment(at: venvDirectory, fileManager: fileManager) {
            try? fileManager.removeItem(at: venvDirectory)
        }
        if !fileManager.fileExists(atPath: venvDirectory.path) {
            let createResult = Self.runProcess(
                executableURL: preferredPython.executableURL,
                arguments: preferredPython.arguments + ["-m", "venv", venvDirectory.path]
            )
            guard createResult.exitCode == 0 else {
                state = .failed(message: "无法创建本地 Python 环境：\(createResult.stderr.isEmpty ? createResult.stdout : createResult.stderr)")
                return
            }
        }

        let pythonURL = Self.managedPythonURL(runtimeRoot: runtimeRoot)
        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            state = .failed(message: "本地 Python 环境创建完成，但找不到可执行文件。")
            return
        }

        state = .preparing(step: "正在更新 pip 与基础工具…")
        let bootstrapResult = Self.runProcess(
            executableURL: pythonURL,
            arguments: ["-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"]
        )
        guard bootstrapResult.exitCode == 0 else {
            state = .failed(message: "基础工具安装失败：\(bootstrapResult.stderr.isEmpty ? bootstrapResult.stdout : bootstrapResult.stderr)")
            return
        }

        state = .preparing(step: "正在安装 SenseVoice 依赖，这一步会稍久一些…")
        let installResult = Self.runProcess(
            executableURL: pythonURL,
            arguments: [
                "-m", "pip", "install",
                "numpy",
                "onnxruntime",
                "torch",
                "funasr-onnx",
                "jieba",
                "modelscope"
            ]
        )
        guard installResult.exitCode == 0 else {
            state = .failed(message: "SenseVoice 依赖安装失败：\(installResult.stderr.isEmpty ? installResult.stdout : installResult.stderr)")
            return
        }

        await detect(modelDirectoryPath: modelDirectoryPath)
    }

    nonisolated static func managedPythonURL(runtimeRoot: URL) -> URL {
        venvDirectory(runtimeRoot: runtimeRoot)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3", isDirectory: false)
    }

    nonisolated static func validateModelDirectory(
        rawPath: String?,
        fileManager: FileManager = .default
    ) -> String? {
        let modelDirectory = LocalSenseVoiceRuntime.modelDirectory(rawPath: rawPath)
        return LocalSenseVoiceRuntime.validateModelDirectory(modelDirectory, fileManager: fileManager)
    }

    nonisolated private static func venvDirectory(runtimeRoot: URL) -> URL {
        runtimeRoot.appendingPathComponent("venv", isDirectory: true)
    }

    nonisolated private static func manifestURL(runtimeRoot: URL) -> URL {
        runtimeRoot.appendingPathComponent("manifest.json", isDirectory: false)
    }

    nonisolated private static func preferredPythonCommand(
        fileManager: FileManager = .default
    ) -> PythonCommand? {
        let directCandidates = [
            "/opt/homebrew/bin/python3.11",
            "/usr/local/bin/python3.11",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11",
            "/opt/homebrew/bin/python3.12",
            "/usr/local/bin/python3.12",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12",
        ]

        if let path = directCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return PythonCommand(
                executableURL: URL(fileURLWithPath: path),
                arguments: [],
                displayName: URL(fileURLWithPath: path).lastPathComponent
            )
        }

        if fileManager.isExecutableFile(atPath: "/usr/bin/env") {
            return PythonCommand(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["python3"],
                displayName: "python3"
            )
        }

        return nil
    }

    nonisolated private static func shouldRecreateEnvironment(
        at venvDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let pythonURL = venvDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3", isDirectory: false)
        guard fileManager.isExecutableFile(atPath: pythonURL.path) else {
            return false
        }

        let result = runProcess(
            executableURL: pythonURL,
            arguments: ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"]
        )
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.hasPrefix("3.14")
    }

    private static func loadManifest(from runtimeRoot: URL) -> LocalSenseVoiceRuntimeManifest? {
        guard
            let data = try? Data(contentsOf: manifestURL(runtimeRoot: runtimeRoot)),
            let manifest = try? JSONDecoder().decode(LocalSenseVoiceRuntimeManifest.self, from: data)
        else {
            return nil
        }
        return manifest
    }

    private static func persistManifest(
        _ manifest: LocalSenseVoiceRuntimeManifest,
        to runtimeRoot: URL,
        fileManager: FileManager
    ) {
        do {
            try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL(runtimeRoot: runtimeRoot), options: .atomic)
        } catch {
            // Ignore manifest write failures; runtime can still be used.
        }
    }

    nonisolated private static func runProcess(
        executableURL: URL,
        arguments: [String]
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private struct PythonCommand {
        let executableURL: URL
        let arguments: [String]
        let displayName: String
    }

    private struct ProbePayload: Decodable {
        let ok: Bool
        let backend: String
        let message: String
        let versions: [String: String]
    }

    private static let probeScript = """
import importlib.metadata
import importlib.util
import json

modules = ["numpy", "onnxruntime", "funasr", "funasr_onnx", "modelscope"]

def has_module(name):
    return importlib.util.find_spec(name) is not None

backend = ""
if has_module("funasr_onnx") and has_module("torch"):
    backend = "funasr_onnx"
elif has_module("funasr") and has_module("torch"):
    backend = "funasr"

versions = {}
for name in modules:
    if has_module(name):
        try:
            versions[name] = importlib.metadata.version(name.replace("_", "-"))
        except Exception:
            versions[name] = "installed"

if not has_module("numpy") or not has_module("onnxruntime"):
    print(json.dumps({
        "ok": False,
        "backend": "",
        "message": "本地运行环境缺少 numpy 或 onnxruntime，请重新准备本地环境。",
        "versions": versions,
    }, ensure_ascii=False))
elif not has_module("torch"):
    print(json.dumps({
        "ok": False,
        "backend": "",
        "message": "本地运行环境缺少 torch，请重新准备本地环境。",
        "versions": versions,
    }, ensure_ascii=False))
elif not backend:
    print(json.dumps({
        "ok": False,
        "backend": "",
        "message": "本地运行环境缺少 funasr_onnx 或 funasr，请重新准备本地环境。",
        "versions": versions,
    }, ensure_ascii=False))
else:
    print(json.dumps({
        "ok": True,
        "backend": backend,
        "message": "本地运行环境可用。",
        "versions": versions,
    }, ensure_ascii=False))
"""
}

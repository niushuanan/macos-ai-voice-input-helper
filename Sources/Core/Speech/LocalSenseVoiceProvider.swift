import Foundation

struct LocalSenseVoiceProvider: SpeechTranscriptionProvider {
    let supportedProviderTypes: [ProviderType] = [.localSenseVoice]

    func transcribe(
        request: SpeechTranscriptionRequest,
        configuration: SpeechProviderConfiguration,
        apiKey _: String
    ) async throws -> SpeechTranscriptionResult {
        if Task.isCancelled {
            throw SpeechTranscriptionError.cancelled
        }

        let modelDirectory = LocalSenseVoiceRuntime.modelDirectory(
            rawPath: configuration.localModelPath
        )

        if let validationError = LocalSenseVoiceRuntime.validateModelDirectory(modelDirectory) {
            throw SpeechTranscriptionError.providerFailure(description: validationError)
        }

        let execution = LocalSenseVoiceRuntime.runWorker(
            mode: .transcribe,
            modelDirectory: modelDirectory,
            audioFileURL: request.clip.fileURL
        )

        guard execution.success else {
            let hintPart = execution.hint.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = hintPart.isEmpty ? execution.message : "\(execution.message) \(hintPart)"
            throw SpeechTranscriptionError.providerFailure(description: detail)
        }

        let transcript = execution.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw SpeechTranscriptionError.invalidResponse
        }

        if Task.isCancelled {
            throw SpeechTranscriptionError.cancelled
        }

        return SpeechTranscriptionResult(
            providerType: configuration.providerType,
            providerName: configuration.providerName,
            modelName: configuration.modelName,
            transcript: transcript
        )
    }
}

enum LocalSenseVoiceHealthChecker {
    static func check(config: ASRConfig) -> ConnectionTestResult {
        let modelDirectory = LocalSenseVoiceRuntime.modelDirectory(rawPath: config.localModelPath)
        if let validationError = LocalSenseVoiceRuntime.validateModelDirectory(modelDirectory) {
            return .failure(
                message: "本地 SenseVoice 检测失败：\(validationError)",
                hint: "请先准备完整模型目录，再重新检测。"
            )
        }

        let execution = LocalSenseVoiceRuntime.runWorker(
            mode: .probe,
            modelDirectory: modelDirectory,
            audioFileURL: nil
        )

        if execution.success {
            let backendHint: String
            if let backend = execution.backend, !backend.isEmpty {
                backendHint = "已检测到 \(backend) 推理后端，可尝试本地识别。"
            } else {
                backendHint = "本地环境可用，可尝试本地识别。"
            }
            return .success(
                message: "本地 SenseVoice 检测通过：\(execution.message)",
                hint: backendHint,
                httpStatus: nil
            )
        }

        return .failure(
            message: "本地 SenseVoice 检测失败：\(execution.message)",
            hint: execution.hint
        )
    }
}

private enum LocalSenseVoiceWorkerMode: String {
    case probe
    case transcribe = "transcribe"
}

private struct LocalSenseVoiceWorkerExecution {
    let success: Bool
    let message: String
    let hint: String
    let transcript: String
    let backend: String?
}

private struct LocalSenseVoiceWorkerPayload: Decodable {
    let ok: Bool
    let message: String?
    let hint: String?
    let transcript: String?
    let backend: String?
}

enum LocalSenseVoiceRuntime {
    private static let requiredFiles = [
        "model.onnx",
        "tokens.json",
        "config.yaml"
    ]

    static func modelDirectory(rawPath: String?) -> URL {
        let normalized = rawPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (normalized?.isEmpty == false)
            ? normalized!
            : defaultSenseVoiceModelPath
        let expanded = NSString(string: candidate).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    static func validateModelDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return "模型目录不存在：\(directory.path)"
        }
        guard isDirectory.boolValue else {
            return "模型路径不是目录：\(directory.path)"
        }

        let missing = requiredFiles.filter { fileName in
            !fileManager.fileExists(atPath: directory.appendingPathComponent(fileName).path)
        }

        if !missing.isEmpty {
            return "模型目录缺少文件：\(missing.joined(separator: "、"))"
        }

        return nil
    }

    fileprivate static func runWorker(
        mode: LocalSenseVoiceWorkerMode,
        modelDirectory: URL,
        audioFileURL: URL?
    ) -> LocalSenseVoiceWorkerExecution {
        let runtimeRoot = LocalSenseVoiceRuntimeManager.defaultRuntimeRoot()
        let pythonURL = LocalSenseVoiceRuntimeManager.managedPythonURL(runtimeRoot: runtimeRoot)
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            return LocalSenseVoiceWorkerExecution(
                success: false,
                message: "本地运行环境还没准备。",
                hint: "请先在模型页点“准备本地环境”，完成后再检测或转写。",
                transcript: "",
                backend: nil
            )
        }

        let process = Process()
        process.executableURL = pythonURL

        var arguments = [
            "-c",
            workerScript,
            "--mode",
            mode.rawValue,
            "--model-dir",
            modelDirectory.path
        ]
        if let audioFileURL {
            arguments.append(contentsOf: ["--audio", audioFileURL.path])
        }
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return LocalSenseVoiceWorkerExecution(
                success: false,
                message: "无法启动本地 SenseVoice worker。",
                hint: "请先在模型页准备本地运行环境，再重试。",
                transcript: "",
                backend: nil
            )
        }

        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let payload = decodePayload(from: output)
        let stderrText = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let payload {
            let message = payload.message?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "worker 未返回消息。"
            let hint = payload.hint?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultHint(for: mode)
            let transcript = payload.transcript?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let backend = payload.backend?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalSenseVoiceWorkerExecution(
                success: payload.ok,
                message: message,
                hint: hint,
                transcript: transcript,
                backend: backend
            )
        }

        let outputText = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reason = !stderrText.isEmpty ? stderrText : (!outputText.isEmpty ? outputText : "worker 无输出")
        return LocalSenseVoiceWorkerExecution(
            success: false,
            message: "本地 worker 执行失败：\(reason)",
            hint: defaultHint(for: mode),
            transcript: "",
            backend: nil
        )
    }

    private static func decodePayload(from data: Data) -> LocalSenseVoiceWorkerPayload? {
        guard !data.isEmpty else {
            return nil
        }

        if let payload = try? JSONDecoder().decode(LocalSenseVoiceWorkerPayload.self, from: data) {
            return payload
        }

        guard
            let raw = String(data: data, encoding: .utf8),
            let lastLine = raw
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last,
            let lineData = lastLine.data(using: .utf8),
            let payload = try? JSONDecoder().decode(LocalSenseVoiceWorkerPayload.self, from: lineData)
        else {
            return nil
        }

        return payload
    }

    private static func defaultHint(for mode: LocalSenseVoiceWorkerMode) -> String {
        switch mode {
        case .probe:
            return "建议使用 Python 3.11 虚拟环境，并安装 onnxruntime、numpy 与 funasr。"
        case .transcribe:
            return "请先在模型页通过“检测本地 ASR”，再尝试本地转写。"
        }
    }

    private static let workerScript = """
import argparse
import json
import pathlib
import sys
import traceback

def emit(ok, message, hint="", transcript="", backend=""):
    payload = {
        "ok": bool(ok),
        "message": str(message),
        "hint": str(hint),
        "transcript": str(transcript),
        "backend": str(backend),
    }
    print(json.dumps(payload, ensure_ascii=False))
    return 0 if ok else 1

def has_module(name):
    try:
        __import__(name)
        return True
    except Exception:
        return False

def extract_text(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="ignore").strip()
    if isinstance(value, dict):
        for key in ("text", "sentence", "transcript", "value"):
            text = extract_text(value.get(key))
            if text:
                return text
        for nested in value.values():
            text = extract_text(nested)
            if text:
                return text
        return ""
    if isinstance(value, (list, tuple)):
        parts = [extract_text(item) for item in value]
        parts = [part for part in parts if part]
        return "\\n".join(parts)
    return str(value).strip()

def run_funasr(model_dir, audio_path):
    from funasr import AutoModel
    model = AutoModel(model=str(model_dir), trust_remote_code=True, disable_update=True)
    result = model.generate(input=str(audio_path))
    return extract_text(result)

def run_funasr_onnx(model_dir, audio_path):
    from funasr_onnx import SenseVoiceSmall
    try:
        model = SenseVoiceSmall(model_dir=str(model_dir), quantize=False)
    except TypeError:
        model = SenseVoiceSmall(str(model_dir))

    try:
        result = model(str(audio_path))
    except TypeError:
        result = model.inference(str(audio_path))
    return extract_text(result)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["probe", "transcribe"], required=True)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--audio", default="")
    args = parser.parse_args()

    model_dir = pathlib.Path(args.model_dir).expanduser()
    required_files = ["model.onnx", "tokens.json", "config.yaml"]
    missing = [name for name in required_files if not (model_dir / name).exists()]
    if missing:
        return emit(
            False,
            "模型目录缺少文件：" + "、".join(missing),
            "请确认 SenseVoice Small 模型目录完整。"
        )

    if not has_module("onnxruntime") or not has_module("numpy"):
        return emit(
            False,
            "缺少基础依赖 onnxruntime 或 numpy。",
            "建议使用 Python 3.11 虚拟环境并执行：pip install onnxruntime numpy"
        )

    backend = ""
    if has_module("funasr"):
        backend = "funasr"
    elif has_module("funasr_onnx"):
        backend = "funasr_onnx"

    if args.mode == "probe":
        if not backend:
            return emit(
                False,
                "缺少 SenseVoice 推理后端。",
                "请安装 funasr（推荐）或 funasr-onnx。示例：pip install funasr modelscope"
            )
        return emit(True, "本地环境可用。", "可切换到本地 SenseVoice。", backend=backend)

    audio_path = pathlib.Path(args.audio).expanduser()
    if not audio_path.exists():
        return emit(False, "录音文件不存在。", "请重新开始语音会话后再试。", backend=backend)

    if not backend:
        return emit(
            False,
            "缺少 SenseVoice 推理后端。",
            "请安装 funasr（推荐）或 funasr-onnx。示例：pip install funasr modelscope"
        )

    try:
        if backend == "funasr":
            text = run_funasr(model_dir, audio_path)
        else:
            text = run_funasr_onnx(model_dir, audio_path)
    except Exception as error:
        debug = traceback.format_exc(limit=2)
        return emit(
            False,
            "本地推理执行失败：" + str(error),
            "请检查 Python 依赖、模型版本与运行权限。\\n" + debug,
            backend=backend
        )

    normalized = text.strip()
    if not normalized:
        return emit(False, "本地推理返回空文本。", "请确认音频内容有效，或切回云端 ASR。", backend=backend)

    return emit(True, "本地推理完成。", "识别成功。", transcript=normalized, backend=backend)

if __name__ == "__main__":
    sys.exit(main())
"""
}

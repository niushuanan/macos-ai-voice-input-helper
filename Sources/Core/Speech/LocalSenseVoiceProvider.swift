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

        let execution = await LocalSenseVoiceRuntime.runTranscription(
            modelDirectory: modelDirectory,
            audioFileURL: request.clip.fileURL,
            hotwordText: request.dictionaryHotwordText
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
            audioFileURL: nil,
            hotwordText: nil
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
    case daemon
}

private struct LocalSenseVoiceWorkerExecution {
    let success: Bool
    let message: String
    let hint: String
    let transcript: String
    let backend: String?
}

private struct LocalSenseVoiceWorkerPayload: Decodable {
    let id: String?
    let ok: Bool
    let message: String?
    let hint: String?
    let transcript: String?
    let backend: String?
}

struct LocalSenseVoiceDaemonRequest: Encodable {
    let id: String
    let action: String
    let audio: String?
    let hotword: String?
}

private actor LocalSenseVoiceDaemonClient {
    static let shared = LocalSenseVoiceDaemonClient()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var activeModelDirectoryPath: String?
    private var pendingStdoutBuffer = Data()

    func transcribe(
        modelDirectory: URL,
        audioFileURL: URL,
        hotwordText: String?
    ) -> LocalSenseVoiceWorkerExecution {
        let runtimeRoot = LocalSenseVoiceRuntimeManager.defaultRuntimeRoot()
        guard let pythonURL = LocalSenseVoiceRuntime.pythonExecutableURL(runtimeRoot: runtimeRoot) else {
            return LocalSenseVoiceWorkerExecution(
                success: false,
                message: "本地运行环境还没准备。",
                hint: "请先在模型页点“准备本地环境”，完成后再检测或转写。",
                transcript: "",
                backend: nil
            )
        }

        guard ensureDaemonReady(modelDirectory: modelDirectory, pythonURL: pythonURL) else {
            let detail = capturedStderr()
            return LocalSenseVoiceWorkerExecution(
                success: false,
                message: "本地 daemon 启动失败：\(detail.isEmpty ? "无输出" : detail)",
                hint: "将自动回退到单次 worker，请稍后重试。",
                transcript: "",
                backend: nil
            )
        }

        guard
            let stdinHandle,
            let stdoutHandle
        else {
            return LocalSenseVoiceWorkerExecution(
                success: false,
                message: "本地 daemon 通道不可用。",
                hint: "将自动回退到单次 worker，请稍后重试。",
                transcript: "",
                backend: nil
            )
        }

        let requestID = UUID().uuidString
        let normalizedHotword = hotwordText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let request = LocalSenseVoiceDaemonRequest(
            id: requestID,
            action: "transcribe",
            audio: audioFileURL.path,
            hotword: (normalizedHotword?.isEmpty == false) ? normalizedHotword : nil
        )

        guard writeJSONLine(request, to: stdinHandle) else {
            stopDaemon()
            return LocalSenseVoiceWorkerExecution(
                success: false,
                message: "本地 daemon 写入失败。",
                hint: "将自动回退到单次 worker，请稍后重试。",
                transcript: "",
                backend: nil
            )
        }

        for _ in 0..<12 {
            guard let line = readLine(from: stdoutHandle) else {
                stopDaemon()
                return LocalSenseVoiceWorkerExecution(
                    success: false,
                    message: "本地 daemon 无响应。",
                    hint: "将自动回退到单次 worker，请稍后重试。",
                    transcript: "",
                    backend: nil
                )
            }

            guard
                let data = line.data(using: .utf8),
                let payload = LocalSenseVoiceRuntime.decodePayload(from: data)
            else {
                continue
            }

            if let payloadID = payload.id, payloadID != requestID {
                continue
            }

            let message = payload.message?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "daemon 未返回消息。"
            let hint = payload.hint?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "请检查本地推理环境。"
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

        return LocalSenseVoiceWorkerExecution(
            success: false,
            message: "本地 daemon 返回格式异常。",
            hint: "将自动回退到单次 worker，请稍后重试。",
            transcript: "",
            backend: nil
        )
    }

    private func ensureDaemonReady(modelDirectory: URL, pythonURL: URL) -> Bool {
        if
            let process,
            process.isRunning,
            activeModelDirectoryPath == modelDirectory.path,
            stdinHandle != nil,
            stdoutHandle != nil
        {
            return true
        }

        stopDaemon()

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [
            "-c",
            LocalSenseVoiceRuntime.workerScript,
            "--mode",
            LocalSenseVoiceWorkerMode.daemon.rawValue,
            "--model-dir",
            modelDirectory.path
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return false
        }

        self.process = process
        stdinHandle = inputPipe.fileHandleForWriting
        stdoutHandle = outputPipe.fileHandleForReading
        stderrHandle = errorPipe.fileHandleForReading
        activeModelDirectoryPath = modelDirectory.path
        pendingStdoutBuffer.removeAll(keepingCapacity: false)

        guard let startupLine = readLine(from: outputPipe.fileHandleForReading) else {
            stopDaemon()
            return false
        }
        guard
            let startupData = startupLine.data(using: .utf8),
            let startupPayload = LocalSenseVoiceRuntime.decodePayload(from: startupData),
            startupPayload.ok
        else {
            stopDaemon()
            return false
        }
        return true
    }

    private func stopDaemon() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        activeModelDirectoryPath = nil
        pendingStdoutBuffer.removeAll(keepingCapacity: false)
    }

    private func writeJSONLine<T: Encodable>(_ payload: T, to handle: FileHandle) -> Bool {
        guard
            let data = try? JSONEncoder().encode(payload),
            let newline = "\n".data(using: .utf8)
        else {
            return false
        }

        do {
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: newline)
            return true
        } catch {
            return false
        }
    }

    private func readLine(from handle: FileHandle) -> String? {
        while true {
            if let newlineIndex = pendingStdoutBuffer.firstIndex(of: 0x0A) {
                let lineData = pendingStdoutBuffer.prefix(upTo: newlineIndex)
                let nextIndex = pendingStdoutBuffer.index(after: newlineIndex)
                pendingStdoutBuffer.removeSubrange(pendingStdoutBuffer.startIndex..<nextIndex)
                return String(data: Data(lineData), encoding: .utf8)
            }

            let chunk = handle.availableData
            if chunk.isEmpty {
                guard !pendingStdoutBuffer.isEmpty else {
                    return nil
                }
                defer { pendingStdoutBuffer.removeAll(keepingCapacity: false) }
                return String(data: pendingStdoutBuffer, encoding: .utf8)
            }

            pendingStdoutBuffer.append(chunk)
            if pendingStdoutBuffer.count > 512 * 1024 {
                let oversized = pendingStdoutBuffer
                pendingStdoutBuffer.removeAll(keepingCapacity: false)
                return String(data: oversized, encoding: .utf8)
            }
        }
    }

    private func capturedStderr() -> String {
        guard let stderrHandle else {
            return ""
        }
        let data = stderrHandle.availableData
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum LocalSenseVoiceRuntime {
    private static let requiredFiles = [
        "model.onnx",
        "tokens.json",
        "config.yaml",
        "am.mvn",
        "chn_jpn_yue_eng_ko_spectok.bpe.model"
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

    fileprivate static func pythonExecutableURL(runtimeRoot: URL) -> URL? {
        let pythonURL = LocalSenseVoiceRuntimeManager.managedPythonURL(runtimeRoot: runtimeRoot)
        return FileManager.default.isExecutableFile(atPath: pythonURL.path)
            ? pythonURL
            : nil
    }

    fileprivate static func runTranscription(
        modelDirectory: URL,
        audioFileURL: URL,
        hotwordText: String?
    ) async -> LocalSenseVoiceWorkerExecution {
        let daemonExecution = await LocalSenseVoiceDaemonClient.shared.transcribe(
            modelDirectory: modelDirectory,
            audioFileURL: audioFileURL,
            hotwordText: hotwordText
        )
        if daemonExecution.success {
            return daemonExecution
        }

        let fallbackExecution = runWorker(
            mode: .transcribe,
            modelDirectory: modelDirectory,
            audioFileURL: audioFileURL,
            hotwordText: hotwordText
        )
        if fallbackExecution.success {
            return fallbackExecution
        }

        let combinedMessage = "\(daemonExecution.message)；\(fallbackExecution.message)"
        let combinedHint = "\(daemonExecution.hint) \(fallbackExecution.hint)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalSenseVoiceWorkerExecution(
            success: false,
            message: combinedMessage,
            hint: combinedHint,
            transcript: "",
            backend: fallbackExecution.backend ?? daemonExecution.backend
        )
    }

    fileprivate static func runWorker(
        mode: LocalSenseVoiceWorkerMode,
        modelDirectory: URL,
        audioFileURL: URL?,
        hotwordText: String?
    ) -> LocalSenseVoiceWorkerExecution {
        let runtimeRoot = LocalSenseVoiceRuntimeManager.defaultRuntimeRoot()
        guard let pythonURL = pythonExecutableURL(runtimeRoot: runtimeRoot) else {
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
        if
            let hotwordText = hotwordText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !hotwordText.isEmpty
        {
            arguments.append(contentsOf: ["--hotword", hotwordText])
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

    fileprivate static func decodePayload(from data: Data) -> LocalSenseVoiceWorkerPayload? {
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
            return "建议使用 Python 3.11 虚拟环境，并安装 onnxruntime、numpy、torch 与 funasr-onnx。"
        case .transcribe:
            return "请先在模型页通过“检测本地 ASR”，再尝试本地转写。"
        case .daemon:
            return "本地常驻进程异常，正在回退到单次 worker。"
        }
    }

    fileprivate static let workerScript = """
import argparse
import json
import pathlib
import sys
import traceback

def emit(ok, message, hint="", transcript="", backend="", request_id=None):
    payload = {
        "ok": bool(ok),
        "message": str(message),
        "hint": str(hint),
        "transcript": str(transcript),
        "backend": str(backend),
    }
    if request_id is not None:
        payload["id"] = str(request_id)
    print(json.dumps(payload, ensure_ascii=False), flush=True)
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

def detect_backend():
    if has_module("funasr_onnx") and has_module("torch"):
        return "funasr_onnx"
    if has_module("funasr") and has_module("torch"):
        return "funasr"
    return ""

def load_model(backend, model_dir):
    if backend == "funasr":
        from funasr import AutoModel
        return AutoModel(model=str(model_dir), trust_remote_code=True, disable_update=True)
    from funasr_onnx import SenseVoiceSmall
    try:
        return SenseVoiceSmall(model_dir=str(model_dir), quantize=False)
    except TypeError:
        return SenseVoiceSmall(str(model_dir))

def with_hotword_variants(callers, fallback):
    for call in callers:
        try:
            return call()
        except TypeError:
            continue
    return fallback()

def infer_text(backend, model, audio_path, hotword_text=""):
    if backend == "funasr":
        if hotword_text:
            result = with_hotword_variants(
                [
                    lambda: model.generate(input=str(audio_path), hotword=hotword_text),
                    lambda: model.generate(input=str(audio_path), hotword_text=hotword_text),
                ],
                fallback=lambda: model.generate(input=str(audio_path))
            )
            return extract_text(result)
        return extract_text(model.generate(input=str(audio_path)))

    def infer_by_call():
        if hotword_text:
            return with_hotword_variants(
                [
                    lambda: model(str(audio_path), hotword=hotword_text),
                    lambda: model(str(audio_path), hotword_text=hotword_text),
                ],
                fallback=lambda: model(str(audio_path))
            )
        return model(str(audio_path))

    def infer_by_method():
        if hotword_text:
            return with_hotword_variants(
                [
                    lambda: model.inference(str(audio_path), hotword=hotword_text),
                    lambda: model.inference(str(audio_path), hotword_text=hotword_text),
                ],
                fallback=lambda: model.inference(str(audio_path))
            )
        return model.inference(str(audio_path))

    try:
        result = infer_by_call()
    except TypeError:
        result = infer_by_method()
    return extract_text(result)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["probe", "transcribe", "daemon"], required=True)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--audio", default="")
    parser.add_argument("--hotword", default="")
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
            "建议使用 Python 3.11 虚拟环境并执行：pip install onnxruntime numpy torch"
        )

    backend = detect_backend()

    if args.mode == "probe":
        if not backend:
            return emit(
                False,
                "缺少 SenseVoice 推理后端。",
                "请安装 funasr-onnx（推荐），并补全 torch。示例：pip install torch funasr-onnx modelscope"
            )
        return emit(True, "本地环境可用。", "可切换到本地 SenseVoice。", backend=backend)

    if not backend:
        return emit(
            False,
            "缺少 SenseVoice 推理后端。",
            "请安装 funasr-onnx（推荐），并补全 torch。示例：pip install torch funasr-onnx modelscope"
        )

    try:
        model = load_model(backend, model_dir)
    except Exception as error:
        debug = traceback.format_exc(limit=2)
        return emit(
            False,
            "模型加载失败：" + str(error),
            "请检查 Python 依赖、模型版本与运行权限。\\n" + debug,
            backend=backend
        )

    if args.mode == "daemon":
        emit(True, "daemon-ready", "常驻转写已就绪。", backend=backend)
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            request_id = None
            try:
                payload = json.loads(line)
                request_id = payload.get("id")
            except Exception:
                emit(False, "请求解析失败。", "请检查 daemon 输入格式。", backend=backend, request_id=request_id)
                continue

            action = str(payload.get("action", "transcribe"))
            if action == "ping":
                emit(True, "pong", "daemon 活跃。", backend=backend, request_id=request_id)
                continue
            if action != "transcribe":
                emit(False, "不支持的 action。", "仅支持 transcribe。", backend=backend, request_id=request_id)
                continue

            audio_path = pathlib.Path(str(payload.get("audio", ""))).expanduser()
            if not audio_path.exists():
                emit(False, "录音文件不存在。", "请重新开始语音会话后再试。", backend=backend, request_id=request_id)
                continue

            hotword_text = str(payload.get("hotword", "")).strip()
            try:
                text = infer_text(backend, model, audio_path, hotword_text=hotword_text)
            except Exception as error:
                debug = traceback.format_exc(limit=2)
                emit(
                    False,
                    "本地推理执行失败：" + str(error),
                    "请检查 Python 依赖、模型版本与运行权限。\\n" + debug,
                    backend=backend,
                    request_id=request_id
                )
                continue

            normalized = text.strip()
            if not normalized:
                emit(
                    False,
                    "本地推理返回空文本。",
                    "请确认音频内容有效，或切回云端 ASR。",
                    backend=backend,
                    request_id=request_id
                )
                continue

            emit(
                True,
                "本地推理完成。",
                "识别成功。",
                transcript=normalized,
                backend=backend,
                request_id=request_id
            )
        return 0

    audio_path = pathlib.Path(args.audio).expanduser()
    if not audio_path.exists():
        return emit(False, "录音文件不存在。", "请重新开始语音会话后再试。", backend=backend)

    try:
        text = infer_text(backend, model, audio_path, hotword_text=args.hotword.strip())
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

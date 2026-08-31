import Foundation

protocol WebSocketTransport: Sendable {
    func connect(request: URLRequest) async throws
    func send(data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

protocol RealtimeASRSession: Sendable {
    var events: AsyncThrowingStream<StreamingTranscriptEvent, Error> { get }

    func start(context: VoiceSessionContext) async throws
    func append(_ chunk: VoiceAudioChunk) async throws
    func finish() async throws
    func cancel() async
}

enum WebSocketJSONFrameEncoder {
    static func text(from data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoiceKernelFailure.invalidServerEvent("WebSocket JSON 不是 UTF-8")
        }
        return text
    }
}

final class WebSocketConnectionObserver: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var resolution: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var timeoutWorkItem: DispatchWorkItem?

    func waitUntilOpen(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let resolution {
                lock.unlock()
                continuation.resume(with: resolution)
                return
            }

            waiters.append(continuation)
            if timeoutWorkItem == nil {
                let workItem = DispatchWorkItem { [weak self] in
                    self?.markFailed(
                        VoiceKernelFailure.connection("WebSocket 握手超时")
                    )
                }
                timeoutWorkItem = workItem
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + max(0.1, timeout),
                    execute: workItem
                )
            }
            lock.unlock()
        }
    }

    func markOpened() {
        resolve(.success(()))
    }

    func markFailed(_ error: Error) {
        resolve(.failure(error))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        markOpened()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else {
            return
        }
        markFailed(error)
    }

    private func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard resolution == nil else {
            lock.unlock()
            return
        }
        resolution = result
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()

        continuations.forEach { $0.resume(with: result) }
    }
}

actor URLSessionWebSocketTransport: WebSocketTransport {
    private let configuration: URLSessionConfiguration
    private let connectionTimeout: TimeInterval
    private var session: URLSession?
    private var connectionObserver: WebSocketConnectionObserver?
    private var task: URLSessionWebSocketTask?

    init(
        configuration: URLSessionConfiguration = .default,
        connectionTimeout: TimeInterval = 8
    ) {
        self.configuration = configuration
        self.connectionTimeout = max(0.1, connectionTimeout)
    }

    func connect(request: URLRequest) async throws {
        guard task == nil else {
            throw VoiceKernelFailure.sessionBusy
        }
        let observer = WebSocketConnectionObserver()
        let session = URLSession(
            configuration: configuration,
            delegate: observer,
            delegateQueue: nil
        )
        let webSocketTask = session.webSocketTask(with: request)
        self.session = session
        connectionObserver = observer
        task = webSocketTask
        webSocketTask.resume()
        do {
            try await observer.waitUntilOpen(timeout: connectionTimeout)
        } catch {
            webSocketTask.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            self.session = nil
            connectionObserver = nil
            task = nil
            throw error
        }
    }

    func send(data: Data) async throws {
        guard let task else {
            throw VoiceKernelFailure.connection("连接尚未建立")
        }
        try await task.send(.string(WebSocketJSONFrameEncoder.text(from: data)))
    }

    func receive() async throws -> Data {
        guard let task else {
            throw VoiceKernelFailure.connection("连接尚未建立")
        }
        switch try await task.receive() {
        case let .data(data):
            return data
        case let .string(text):
            return Data(text.utf8)
        @unknown default:
            throw VoiceKernelFailure.invalidServerEvent("未知 WebSocket 消息类型")
        }
    }

    func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        connectionObserver = nil
    }
}

actor QwenRealtimeASRSession: RealtimeASRSession {
    nonisolated let events: AsyncThrowingStream<StreamingTranscriptEvent, Error>

    private enum State {
        case idle
        case active
        case finishing
        case finished
        case cancelled
        case failed
    }

    private let transport: any WebSocketTransport
    private let configuration: QwenRealtimeConfiguration
    private let eventContinuation: AsyncThrowingStream<StreamingTranscriptEvent, Error>.Continuation

    private var state: State = .idle
    private var terminalError: Error?
    private var receiveTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var didCloseTransport = false

    init(
        transport: any WebSocketTransport = URLSessionWebSocketTransport(),
        configuration: QwenRealtimeConfiguration
    ) {
        self.transport = transport
        self.configuration = configuration

        var capturedContinuation: AsyncThrowingStream<StreamingTranscriptEvent, Error>.Continuation?
        events = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            capturedContinuation = continuation
        }
        eventContinuation = capturedContinuation!
    }

    func start(context: VoiceSessionContext) async throws {
        guard state == .idle else {
            throw VoiceKernelFailure.sessionBusy
        }

        let endpoint = try QwenRealtimeEndpointResolver.resolve(
            baseURL: configuration.baseURL,
            model: configuration.model
        )
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw VoiceKernelFailure.connection("API Key 为空")
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        do {
            try await transport.connect(request: request)
            state = .active
            beginReceiving()
            let sessionUpdate = try QwenRealtimeCommandEncoder.sessionUpdate(
                contextText: context.asrContextText
            )
            try await transport.send(data: sessionUpdate)
        } catch {
            let failure = normalizedFailure(error)
            await terminate(with: failure)
            throw failure
        }
    }

    func append(_ chunk: VoiceAudioChunk) async throws {
        guard state == .active else {
            throw currentFailure()
        }

        do {
            try await transport.send(
                data: QwenRealtimeCommandEncoder.audioAppend(chunk.pcmData)
            )
        } catch {
            let failure = normalizedFailure(error)
            await terminate(with: failure)
            throw failure
        }
    }

    func finish() async throws {
        switch state {
        case .finished:
            return
        case .active:
            state = .finishing
        case .idle, .finishing:
            throw VoiceKernelFailure.sessionBusy
        case .cancelled, .failed:
            throw currentFailure()
        }

        do {
            try await transport.send(data: QwenRealtimeCommandEncoder.finish())
        } catch {
            let failure = normalizedFailure(error)
            await terminate(with: failure)
            throw failure
        }

        try await waitForSessionFinished()
    }

    func cancel() async {
        guard !isTerminal else {
            return
        }
        state = .cancelled
        receiveTask?.cancel()
        timeoutTask?.cancel()
        eventContinuation.finish()
        resumeFinishContinuation(throwing: VoiceKernelFailure.cancelled)
        await closeTransportOnce()
    }

    private var isTerminal: Bool {
        switch state {
        case .finished, .cancelled, .failed:
            return true
        case .idle, .active, .finishing:
            return false
        }
    }

    private func beginReceiving() {
        receiveTask = Task { [weak self] in
            await self?.receiveMessages()
        }
    }

    private func receiveMessages() async {
        do {
            while !Task.isCancelled, !isTerminal {
                let data = try await transport.receive()
                if let event = try QwenRealtimeEventParser.parse(data) {
                    await handle(event)
                }
            }
        } catch is CancellationError {
            if !isTerminal {
                await terminate(with: VoiceKernelFailure.cancelled)
            }
        } catch {
            if !isTerminal {
                await terminate(with: normalizedFailure(error))
            }
        }
    }

    private func handle(_ event: StreamingTranscriptEvent) async {
        guard !isTerminal else {
            return
        }

        eventContinuation.yield(event)
        guard event == .sessionFinished else {
            return
        }

        state = .finished
        timeoutTask?.cancel()
        eventContinuation.finish()
        resumeFinishContinuation()
        await closeTransportOnce()
    }

    private func waitForSessionFinished() async throws {
        if state == .finished {
            return
        }
        if state == .cancelled || state == .failed {
            throw currentFailure()
        }

        try await withCheckedThrowingContinuation { continuation in
            if state == .finished {
                continuation.resume()
                return
            }
            if state == .cancelled || state == .failed {
                continuation.resume(throwing: currentFailure())
                return
            }

            finishContinuation = continuation
            let timeout = max(0.1, configuration.finalizationTimeout)
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else {
                    return
                }
                await self?.handleFinalizationTimeout()
            }
        }
    }

    private func handleFinalizationTimeout() async {
        guard state == .finishing else {
            return
        }
        await terminate(with: VoiceKernelFailure.finalizationTimeout)
    }

    private func terminate(with error: Error) async {
        guard !isTerminal else {
            return
        }
        state = .failed
        terminalError = error
        receiveTask?.cancel()
        timeoutTask?.cancel()
        eventContinuation.finish(throwing: error)
        resumeFinishContinuation(throwing: error)
        await closeTransportOnce()
    }

    private func resumeFinishContinuation(throwing error: Error? = nil) {
        guard let continuation = finishContinuation else {
            return
        }
        finishContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    private func closeTransportOnce() async {
        guard !didCloseTransport else {
            return
        }
        didCloseTransport = true
        await transport.close()
    }

    private func currentFailure() -> Error {
        if let terminalError {
            return terminalError
        }
        switch state {
        case .cancelled:
            return VoiceKernelFailure.cancelled
        case .idle, .finishing:
            return VoiceKernelFailure.sessionBusy
        case .failed:
            return VoiceKernelFailure.connection("实时语音会话已结束")
        case .finished:
            return VoiceKernelFailure.cancelled
        case .active:
            return VoiceKernelFailure.sessionBusy
        }
    }

    private func normalizedFailure(_ error: Error) -> Error {
        if let failure = error as? VoiceKernelFailure {
            return failure
        }
        if error is CancellationError {
            return VoiceKernelFailure.cancelled
        }
        return VoiceKernelFailure.connection(
            ASRConnectionTester.redactSensitiveText(error.localizedDescription)
        )
    }
}

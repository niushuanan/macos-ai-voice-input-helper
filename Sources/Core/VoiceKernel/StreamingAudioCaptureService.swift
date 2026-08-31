import AVFoundation
import Combine
import Foundation

enum AudioChunkEnqueueResult: Equatable {
    case enqueued
    case overflow
}

struct BoundedAudioChunkQueue {
    private let capacity: Int
    private var storage: [VoiceAudioChunk] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func enqueue(_ chunk: VoiceAudioChunk) -> AudioChunkEnqueueResult {
        guard storage.count < capacity else {
            return .overflow
        }
        storage.append(chunk)
        return .enqueued
    }

    mutating func drain() -> [VoiceAudioChunk] {
        defer { storage.removeAll(keepingCapacity: true) }
        return storage
    }
}

struct PCMChunkFramer {
    private let bytesPerChunk: Int
    private let bytesPerSecond: Double
    private var pending = Data()
    private var nextSequence = 0

    init(bytesPerChunk: Int, bytesPerSecond: Double) {
        self.bytesPerChunk = max(1, bytesPerChunk)
        self.bytesPerSecond = max(1, bytesPerSecond)
    }

    mutating func append(_ data: Data) -> [VoiceAudioChunk] {
        guard !data.isEmpty else {
            return []
        }
        pending.append(data)

        var chunks: [VoiceAudioChunk] = []
        while pending.count >= bytesPerChunk {
            let chunkData = Data(pending.prefix(bytesPerChunk))
            pending.removeFirst(bytesPerChunk)
            chunks.append(makeChunk(data: chunkData))
        }
        return chunks
    }

    mutating func finish() -> [VoiceAudioChunk] {
        guard !pending.isEmpty else {
            return []
        }
        let remainder = pending
        pending.removeAll(keepingCapacity: true)
        return [makeChunk(data: remainder)]
    }

    private mutating func makeChunk(data: Data) -> VoiceAudioChunk {
        defer { nextSequence += 1 }
        return VoiceAudioChunk(
            sequence: nextSequence,
            pcmData: data,
            duration: Double(data.count) / bytesPerSecond
        )
    }
}

@MainActor
protocol StreamingAudioCapture: AnyObject {
    var preferredSampleRate: Double { get }
    var levelPublisher: AnyPublisher<Double, Never> { get }
    var isRecording: Bool { get }

    func startStreamingCapture() throws -> AsyncThrowingStream<VoiceAudioChunk, Error>
    func stopStreamingCapture() throws -> RecordedAudioClip
    func cancelStreamingCapture()
    func removeClip(at url: URL)
    func purgeStaleTemporaryFiles(olderThan age: TimeInterval) -> Int
}

@MainActor
final class AVAudioEngineStreamingCaptureService: AudioCaptureService, StreamingAudioCapture {
    let preferredSampleRate: Double
    let audioFormatDescription = "实时 PCM 16kHz 单声道 + WAV 兜底"

    private let temporaryDirectory: URL
    private let fileManager: FileManager
    private let processingQueue = DispatchQueue(
        label: "com.niushuanan.PulseType.voice-audio",
        qos: .userInitiated
    )
    private let levelSubject = CurrentValueSubject<Double, Never>(0)
    private let bytesPerChunk: Int
    private let streamCapacity: Int

    private var engine: AVAudioEngine?
    private var activePipeline: StreamingAudioPipeline?
    private var activeFileURL: URL?
    private var startedAt: Date?
    private var legacyChunkDrainTask: Task<Void, Never>?

    var levelPublisher: AnyPublisher<Double, Never> {
        levelSubject.eraseToAnyPublisher()
    }

    var isRecording: Bool {
        engine?.isRunning == true && activePipeline != nil
    }

    init(
        temporaryDirectory: URL,
        preferredSampleRate: Double = 16_000,
        chunkDuration: TimeInterval = 0.1,
        bufferedAudioDuration: TimeInterval = 5,
        fileManager: FileManager = .default
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.preferredSampleRate = preferredSampleRate
        self.fileManager = fileManager
        let bytesPerSecond = preferredSampleRate * 2
        bytesPerChunk = max(2, Int(bytesPerSecond * max(0.02, chunkDuration)))
        streamCapacity = max(40, Int(ceil(bufferedAudioDuration / max(0.02, chunkDuration))))
    }

    func startStreamingCapture() throws -> AsyncThrowingStream<VoiceAudioChunk, Error> {
        guard activePipeline == nil else {
            throw AudioCaptureError.recorderBusy
        }

        try ensureTemporaryDirectory()
        let fileURL = makeTemporaryFileURL()
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.recorderNotReady
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: preferredSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioCaptureError.recorderNotReady
        }

        var capturedContinuation: AsyncThrowingStream<VoiceAudioChunk, Error>.Continuation?
        let stream = AsyncThrowingStream<VoiceAudioChunk, Error>(
            bufferingPolicy: .bufferingNewest(streamCapacity)
        ) { continuation in
            capturedContinuation = continuation
        }
        guard let continuation = capturedContinuation else {
            throw AudioCaptureError.recorderNotReady
        }

        let pipeline: StreamingAudioPipeline
        do {
            pipeline = try StreamingAudioPipeline(
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                outputURL: fileURL,
                bytesPerChunk: bytesPerChunk,
                continuation: continuation,
                levelHandler: { [weak self] level in
                    Task { @MainActor in
                        self?.levelSubject.send(level)
                    }
                }
            )
        } catch {
            continuation.finish(throwing: error)
            try? fileManager.removeItem(at: fileURL)
            throw AudioCaptureError.persistenceFailed
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_600,
            format: inputFormat
        ) { [processingQueue] buffer, _ in
            guard let copiedBuffer = Self.copyPCMBuffer(buffer) else {
                return
            }
            processingQueue.async {
                pipeline.process(copiedBuffer)
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            processingQueue.sync {
                pipeline.cancel()
            }
            try? fileManager.removeItem(at: fileURL)
            throw AudioCaptureError.startFailed
        }

        self.engine = engine
        activePipeline = pipeline
        activeFileURL = fileURL
        startedAt = Date()
        return stream
    }

    func startRecording() throws {
        let stream = try startStreamingCapture()
        legacyChunkDrainTask = Task {
            do {
                for try await _ in stream {}
            } catch {
                return
            }
        }
    }

    func stopRecording() throws -> RecordedAudioClip {
        defer {
            legacyChunkDrainTask?.cancel()
            legacyChunkDrainTask = nil
        }
        return try stopStreamingCapture()
    }

    func cancelRecording() {
        legacyChunkDrainTask?.cancel()
        legacyChunkDrainTask = nil
        cancelStreamingCapture()
    }

    func stopStreamingCapture() throws -> RecordedAudioClip {
        guard
            let engine,
            let pipeline = activePipeline,
            let fileURL = activeFileURL
        else {
            throw AudioCaptureError.noClipAvailable
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        processingQueue.sync {
            pipeline.finish()
        }

        let elapsed = startedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        clearActiveState()
        levelSubject.send(0)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw AudioCaptureError.persistenceFailed
        }
        let measuredDuration = Self.audioFileDuration(at: fileURL)
        return RecordedAudioClip(
            id: UUID(),
            fileURL: fileURL,
            duration: max(elapsed, measuredDuration),
            sampleRate: preferredSampleRate,
            createdAt: Date()
        )
    }

    func cancelStreamingCapture() {
        guard let pipeline = activePipeline else {
            return
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        processingQueue.sync {
            pipeline.cancel()
        }
        let fileURL = activeFileURL
        clearActiveState()
        levelSubject.send(0)
        if let fileURL {
            removeClip(at: fileURL)
        }
    }

    func removeClip(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    func purgeStaleTemporaryFiles(olderThan age: TimeInterval) -> Int {
        guard age > 0 else {
            return 0
        }
        try? ensureTemporaryDirectory()
        let now = Date()
        let urls = (try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var removed = 0
        for url in urls where url != activeFileURL {
            guard
                let createdAt = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                now.timeIntervalSince(createdAt) > age
            else {
                continue
            }
            try? fileManager.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    private func clearActiveState() {
        engine = nil
        activePipeline = nil
        activeFileURL = nil
        startedAt = nil
    }

    private func ensureTemporaryDirectory() throws {
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    private func makeTemporaryFileURL() -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return temporaryDirectory.appendingPathComponent(
            "stream-\(timestamp)-\(UUID().uuidString.prefix(8)).wav"
        )
    }

    private nonisolated static func audioFileDuration(at url: URL) -> TimeInterval {
        guard
            let file = try? AVAudioFile(forReading: url),
            file.processingFormat.sampleRate > 0
        else {
            return 0
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private nonisolated static func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else {
            return nil
        }
        copy.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else {
            return nil
        }

        for index in sourceBuffers.indices {
            guard
                let sourceData = sourceBuffers[index].mData,
                let destinationData = destinationBuffers[index].mData
            else {
                continue
            }
            let byteCount = min(
                Int(sourceBuffers[index].mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }
        return copy
    }
}

private final class StreamingAudioPipeline: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let continuation: AsyncThrowingStream<VoiceAudioChunk, Error>.Continuation
    private let levelHandler: @Sendable (Double) -> Void
    private var outputFile: AVAudioFile?
    private var framer: PCMChunkFramer
    private var streamIsTerminated = false

    init(
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        outputURL: URL,
        bytesPerChunk: Int,
        continuation: AsyncThrowingStream<VoiceAudioChunk, Error>.Continuation,
        levelHandler: @escaping @Sendable (Double) -> Void
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.recorderNotReady
        }
        converter.downmix = true
        self.converter = converter
        self.outputFormat = outputFormat
        self.continuation = continuation
        self.levelHandler = levelHandler
        outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        framer = PCMChunkFramer(
            bytesPerChunk: bytesPerChunk,
            bytesPerSecond: outputFormat.sampleRate * 2
        )
    }

    func process(_ inputBuffer: AVAudioPCMBuffer) {
        levelHandler(Self.normalizedLevel(inputBuffer))

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(
            max(1, ceil(Double(inputBuffer.frameLength) * ratio) + 32)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            terminateStream(with: AudioCaptureError.persistenceFailed)
            return
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            terminateStream(with: conversionError)
            return
        }
        guard status != .error else {
            terminateStream(with: AudioCaptureError.persistenceFailed)
            return
        }
        guard outputBuffer.frameLength > 0 else {
            return
        }

        do {
            try outputFile?.write(from: outputBuffer)
        } catch {
            terminateStream(with: error)
            return
        }

        let byteCount = Int(outputBuffer.frameLength) * 2
        let buffers = UnsafeMutableAudioBufferListPointer(outputBuffer.mutableAudioBufferList)
        guard let audioData = buffers.first?.mData else {
            terminateStream(with: AudioCaptureError.persistenceFailed)
            return
        }
        let pcmData = Data(bytes: audioData, count: byteCount)
        emit(framer.append(pcmData))
    }

    func finish() {
        emit(framer.finish())
        outputFile = nil
        if !streamIsTerminated {
            continuation.finish()
            streamIsTerminated = true
        }
    }

    func cancel() {
        outputFile = nil
        if !streamIsTerminated {
            continuation.finish(throwing: VoiceKernelFailure.cancelled)
            streamIsTerminated = true
        }
    }

    private func emit(_ chunks: [VoiceAudioChunk]) {
        guard !streamIsTerminated else {
            return
        }
        for chunk in chunks {
            switch continuation.yield(chunk) {
            case .enqueued:
                continue
            case .dropped:
                terminateStream(with: VoiceKernelFailure.audioBackpressure)
                return
            case .terminated:
                streamIsTerminated = true
                return
            @unknown default:
                terminateStream(with: VoiceKernelFailure.audioBackpressure)
                return
            }
        }
    }

    private func terminateStream(with error: Error) {
        guard !streamIsTerminated else {
            return
        }
        streamIsTerminated = true
        continuation.finish(throwing: error)
    }

    private static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> Double {
        guard
            let channel = buffer.floatChannelData?[0],
            buffer.frameLength > 0
        else {
            return 0
        }
        let count = Int(buffer.frameLength)
        var sum = 0.0
        for index in 0..<count {
            let sample = Double(channel[index])
            sum += sample * sample
        }
        let rms = sqrt(sum / Double(count))
        guard rms > 0 else {
            return 0
        }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 60) / 60))
    }
}

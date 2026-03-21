import AVFoundation
import Combine
import Foundation

struct RecordedAudioClip: Equatable {
    let id: UUID
    let fileURL: URL
    let duration: TimeInterval
    let sampleRate: Double
    let createdAt: Date

    var displaySummary: String {
        let seconds = String(format: "%.1f", duration)
        return "\(seconds) 秒，\(Int(sampleRate))Hz"
    }
}

enum AudioCaptureError: LocalizedError {
    case recorderBusy
    case recorderNotReady
    case startFailed
    case noClipAvailable
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .recorderBusy:
            return "录音器已在运行。"
        case .recorderNotReady:
            return "录音器尚未就绪。"
        case .startFailed:
            return "无法开始录音。"
        case .noClipAvailable:
            return "没有可用录音片段。"
        case .persistenceFailed:
            return "录音片段写入失败。"
        }
    }
}

@MainActor
protocol AudioCaptureService: AnyObject {
    var preferredSampleRate: Double { get }
    var audioFormatDescription: String { get }
    var levelPublisher: AnyPublisher<Double, Never> { get }
    var isRecording: Bool { get }

    func startRecording() throws
    func stopRecording() throws -> RecordedAudioClip
    func cancelRecording()
    func removeClip(at url: URL)
    func purgeStaleTemporaryFiles(olderThan age: TimeInterval) -> Int
}

@MainActor
final class AVAudioRecorderCaptureService: NSObject, AudioCaptureService {
    let preferredSampleRate: Double
    let audioFormatDescription: String = "AAC 单声道（.m4a），用于云端语音接口"

    private let temporaryDirectory: URL
    private let fileManager: FileManager
    private let levelSubject = CurrentValueSubject<Double, Never>(0)
    private var meterTimer: Timer?
    private var recorder: AVAudioRecorder?
    private var activeFileURL: URL?

    var levelPublisher: AnyPublisher<Double, Never> {
        levelSubject.eraseToAnyPublisher()
    }

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    init(
        temporaryDirectory: URL,
        preferredSampleRate: Double = 44_100,
        fileManager: FileManager = .default
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.preferredSampleRate = preferredSampleRate
        self.fileManager = fileManager
        super.init()
    }

    func startRecording() throws {
        guard recorder == nil else {
            throw AudioCaptureError.recorderBusy
        }

        try ensureTemporaryDirectory()
        let fileURL = makeTemporaryFileURL()
        let settings = recorderSettings()

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw AudioCaptureError.startFailed
        }

        self.recorder = recorder
        activeFileURL = fileURL
        startMeterTimer()
    }

    func stopRecording() throws -> RecordedAudioClip {
        guard let recorder, let fileURL = activeFileURL else {
            throw AudioCaptureError.noClipAvailable
        }

        recorder.stop()
        stopMeterTimer()
        self.recorder = nil
        activeFileURL = nil
        levelSubject.send(0)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw AudioCaptureError.persistenceFailed
        }

        return RecordedAudioClip(
            id: UUID(),
            fileURL: fileURL,
            duration: recorder.currentTime,
            sampleRate: preferredSampleRate,
            createdAt: Date()
        )
    }

    func cancelRecording() {
        recorder?.stop()
        stopMeterTimer()
        recorder = nil
        levelSubject.send(0)

        if let activeFileURL {
            removeClip(at: activeFileURL)
            self.activeFileURL = nil
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
        for url in urls {
            guard url != activeFileURL else {
                continue
            }

            let values = try? url.resourceValues(forKeys: [.creationDateKey])
            guard let createdAt = values?.creationDate else {
                continue
            }

            if now.timeIntervalSince(createdAt) > age {
                try? fileManager.removeItem(at: url)
                removed += 1
            }
        }

        return removed
    }

    private func ensureTemporaryDirectory() throws {
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    private func makeTemporaryFileURL() -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = "clip-\(timestamp)-\(UUID().uuidString.prefix(8)).m4a"
        return temporaryDirectory.appendingPathComponent(filename)
    }

    private func recorderSettings() -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: preferredSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 96_000
        ]
    }

    private func startMeterTimer() {
        stopMeterTimer()
        meterTimer = Timer.scheduledTimer(
            timeInterval: 0.05,
            target: self,
            selector: #selector(handleMeterTimer),
            userInfo: nil,
            repeats: true
        )
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private static func normalizedPowerLevel(from averagePower: Float) -> Double {
        let minPower: Float = -60
        if averagePower <= minPower {
            return 0
        }
        if averagePower >= 0 {
            return 1
        }
        return Double((averagePower - minPower) / -minPower)
    }

    @objc
    private func handleMeterTimer() {
        guard let recorder, recorder.isRecording else {
            return
        }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        levelSubject.send(Self.normalizedPowerLevel(from: power))
    }
}

extension AVAudioRecorderCaptureService: AVAudioRecorderDelegate {}

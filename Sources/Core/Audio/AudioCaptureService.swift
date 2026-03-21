import Foundation

protocol AudioCaptureService {
    var preferredSampleRate: Double { get }
    var audioFormatDescription: String { get }
}

struct StubAudioCaptureService: AudioCaptureService {
    let preferredSampleRate: Double = 16_000
    let audioFormatDescription: String = "Mono PCM tuned for speech"
}

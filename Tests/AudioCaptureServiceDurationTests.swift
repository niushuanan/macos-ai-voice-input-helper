import XCTest
@testable import PulseType

final class AudioCaptureServiceDurationTests: XCTestCase {
    func testWAVDurationSecondsComputesFromPCMDataBytes() {
        let bytesPerSecond: UInt64 = 16_000 * 2
        let fileSize = UInt64(44) + bytesPerSecond * 5

        let duration = AVAudioRecorderCaptureService.wavDurationSeconds(
            fileSizeBytes: fileSize,
            sampleRate: 16_000
        )

        XCTAssertEqual(duration, 5, accuracy: 0.0001)
    }

    func testWAVDurationSecondsReturnsZeroWhenOnlyHeaderExists() {
        let duration = AVAudioRecorderCaptureService.wavDurationSeconds(
            fileSizeBytes: 44,
            sampleRate: 16_000
        )

        XCTAssertEqual(duration, 0, accuracy: 0.0001)
    }

    func testWAVDurationSecondsReturnsZeroWhenSampleRateInvalid() {
        let duration = AVAudioRecorderCaptureService.wavDurationSeconds(
            fileSizeBytes: 10_044,
            sampleRate: 0
        )

        XCTAssertEqual(duration, 0, accuracy: 0.0001)
    }
}

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

    func testPCMFramerEmitsMonotonicSequencesAndKeepsExactBoundaries() {
        var framer = PCMChunkFramer(bytesPerChunk: 4, bytesPerSecond: 8)

        XCTAssertEqual(framer.append(Data([0, 1, 2])), [])
        let chunks = framer.append(Data([3, 4, 5, 6, 7]))

        XCTAssertEqual(chunks.map(\.sequence), [0, 1])
        XCTAssertEqual(chunks.map(\.pcmData), [Data([0, 1, 2, 3]), Data([4, 5, 6, 7])])
        XCTAssertEqual(chunks.map(\.duration), [0.5, 0.5])
        XCTAssertEqual(framer.finish(), [])
    }

    func testPCMFramerFlushesRemainderWithExactDuration() {
        var framer = PCMChunkFramer(bytesPerChunk: 4, bytesPerSecond: 8)
        XCTAssertEqual(framer.append(Data([0, 1, 2])), [])

        let remainder = framer.finish()

        XCTAssertEqual(remainder.count, 1)
        XCTAssertEqual(remainder.first?.sequence, 0)
        XCTAssertEqual(remainder.first?.pcmData, Data([0, 1, 2]))
        XCTAssertEqual(remainder.first?.duration ?? 0, 0.375, accuracy: 0.0001)
    }

    func testBoundedAudioQueueReportsOverflowWithoutDroppingExistingChunks() {
        var queue = BoundedAudioChunkQueue(capacity: 2)
        let first = VoiceAudioChunk(sequence: 0, pcmData: Data([0]), duration: 0.1)
        let second = VoiceAudioChunk(sequence: 1, pcmData: Data([1]), duration: 0.1)
        let third = VoiceAudioChunk(sequence: 2, pcmData: Data([2]), duration: 0.1)

        XCTAssertEqual(queue.enqueue(first), .enqueued)
        XCTAssertEqual(queue.enqueue(second), .enqueued)
        XCTAssertEqual(queue.enqueue(third), .overflow)
        XCTAssertEqual(queue.drain(), [first, second])
    }
}

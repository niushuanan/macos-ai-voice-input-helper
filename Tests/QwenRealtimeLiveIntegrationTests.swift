import Foundation
import XCTest
@testable import PulseType

final class QwenRealtimeLiveIntegrationTests: XCTestCase {
    func testConfiguredQwenRealtimeServiceTranscribesPCMFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let markerURL = URL(fileURLWithPath: "/tmp/PulseType.run-live-qwen-test")
        guard environment["PULSETYPE_RUN_LIVE_QWEN_TEST"] == "1"
                || FileManager.default.fileExists(atPath: markerURL.path)
        else {
            throw XCTSkip("Set PULSETYPE_RUN_LIVE_QWEN_TEST=1 to run the live provider check.")
        }
        let apiKey = try environment["PULSETYPE_LIVE_QWEN_API_KEY"]
            ?? Self.loadInstalledASRAPIKey()
        let audioPath = environment["PULSETYPE_LIVE_PCM_WAV"]
            ?? "/tmp/PulseType.live-qwen-fixture.wav"
        let pcmData = try Self.pcmPayload(from: URL(fileURLWithPath: audioPath))
        XCTAssertFalse(pcmData.isEmpty)

        let session = QwenRealtimeASRSession(
            configuration: QwenRealtimeConfiguration(
                baseURL: URL(string: "https://dashscope.aliyuncs.com")!,
                model: "qwen3-asr-flash-realtime",
                apiKey: apiKey,
                finalizationTimeout: 8
            )
        )
        let transcriptTask = Task {
            var ledger = TranscriptLedger()
            for try await event in session.events {
                ledger.apply(event)
            }
            return ledger.snapshot.finalText
        }

        do {
            try await session.start(
                context: VoiceSessionContext(asrContextText: "PulseType，AB-129，产品验收")
            )
        } catch {
            return XCTFail("Live stage=start: \(error.localizedDescription)")
        }
        let bytesPerChunk = 3_200
        var sequence = 0
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + bytesPerChunk, pcmData.count)
            let chunkData = pcmData.subdata(in: offset..<end)
            do {
                try await session.append(
                    VoiceAudioChunk(
                        sequence: sequence,
                        pcmData: chunkData,
                        duration: Double(chunkData.count) / 32_000
                    )
                )
            } catch {
                return XCTFail("Live stage=append sequence=\(sequence): \(error.localizedDescription)")
            }
            sequence += 1
            offset = end
            try await Task.sleep(nanoseconds: 90_000_000)
        }
        do {
            try await session.finish()
        } catch {
            return XCTFail("Live stage=finish: \(error.localizedDescription)")
        }

        let transcript = try await transcriptTask.value
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(normalizedTranscript.isEmpty)
    }

    private static func pcmPayload(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count >= 12,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE"
        else {
            throw VoiceKernelFailure.invalidServerEvent("验收音频不是 WAV")
        }

        var offset = 12
        while offset + 8 <= data.count {
            let identifier = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let sizeOffset = offset + 4
            let chunkSize = Int(data[sizeOffset])
                | (Int(data[sizeOffset + 1]) << 8)
                | (Int(data[sizeOffset + 2]) << 16)
                | (Int(data[sizeOffset + 3]) << 24)
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + chunkSize
            guard payloadEnd <= data.count else {
                break
            }
            if identifier == "data" {
                return data.subdata(in: payloadStart..<payloadEnd)
            }
            offset = payloadEnd + (chunkSize % 2)
        }
        throw VoiceKernelFailure.invalidServerEvent("WAV 缺少 PCM data chunk")
    }

    private static func loadInstalledASRAPIKey() throws -> String {
        struct CredentialEnvelope: Decodable {
            let values: [String: String]
        }

        let credentialsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PulseType/Credentials/credentials.v1.json")
        let data = try Data(contentsOf: credentialsURL)
        let envelope = try JSONDecoder().decode(CredentialEnvelope.self, from: data)
        return try XCTUnwrap(envelope.values["asr.primary"])
    }
}

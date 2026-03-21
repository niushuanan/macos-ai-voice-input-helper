import Combine
import XCTest
@testable import PulseType

@MainActor
final class InteractionCoordinatorTests: XCTestCase {
    func testWakeKeyStartsAndSecondWakeStopsRecording() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        fixture.coordinator.handleWakeInput(context: .dictation)

        XCTAssertEqual(fixture.sessionStore.phase, .listening)
        XCTAssertEqual(fixture.audioCapture.startCallCount, 1)
        XCTAssertTrue(fixture.audioCapture.isRecording)

        fixture.coordinator.handleWakeInput(context: .dictation)

        XCTAssertEqual(fixture.audioCapture.stopCallCount, 1)
        XCTAssertFalse(fixture.audioCapture.isRecording)
        XCTAssertNotEqual(fixture.sessionStore.phase, .listening)
    }

    func testCancelKeyInterruptsSessionAndCreatesCancelledHistory() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleCancelInput()

        XCTAssertEqual(fixture.sessionStore.phase, .cancelled)
        XCTAssertEqual(fixture.audioCapture.cancelCallCount, 1)
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.status, .cancelled)
    }

    private func makeFixture() throws -> InteractionFixture {
        let defaultsSuiteName = "InteractionCoordinatorTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw NSError(domain: "InteractionCoordinatorTests", code: 1)
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)

        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("interaction-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)

        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("interaction-clip-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try Data([0x01, 0x02]).write(to: clipURL)

        let sessionStore = SessionStore()
        let permissionsCenter = PermissionsCenter(
            defaults: defaults,
            microphoneStateResolver: { .granted },
            accessibilityStateResolver: { .granted }
        )
        let audioCapture = FakeAudioCaptureService(
            clip: RecordedAudioClip(
                id: UUID(),
                fileURL: clipURL,
                duration: 0.8,
                sampleRate: 44_100,
                createdAt: Date()
            )
        )
        let providerSettingsStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: MemoryCredentialStoreForInteractionTests()
        )
        let localHistoryStore = LocalHistoryStore(historyDirectory: historyDirectory)
        let appScenePolicyStore = AppScenePolicyStore(defaults: defaults)
        let skillRuleStore = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.interaction.tests")

        let coordinator = InteractionCoordinator(
            sessionStore: sessionStore,
            permissionsCenter: permissionsCenter,
            audioCaptureService: audioCapture,
            providerSettingsStore: providerSettingsStore,
            providerRegistry: SpeechProviderRegistry(providers: []),
            rewriteProviderRegistry: RewriteProviderRegistry(providers: []),
            textOutputCoordinator: FakeTextOutputCoordinator(),
            contextDetector: FixedContextDetector(),
            appScenePolicyStore: appScenePolicyStore,
            localHistoryStore: localHistoryStore,
            skillRuleStore: skillRuleStore
        )

        return InteractionFixture(
            coordinator: coordinator,
            sessionStore: sessionStore,
            audioCapture: audioCapture,
            localHistoryStore: localHistoryStore,
            cleanUp: {
                try? FileManager.default.removeItem(at: historyDirectory)
                try? FileManager.default.removeItem(at: clipURL)
                defaults.removePersistentDomain(forName: defaultsSuiteName)
            }
        )
    }
}

private struct InteractionFixture {
    let coordinator: InteractionCoordinator
    let sessionStore: SessionStore
    let audioCapture: FakeAudioCaptureService
    let localHistoryStore: LocalHistoryStore
    let cleanUp: () -> Void
}

@MainActor
private final class FakeAudioCaptureService: AudioCaptureService {
    let preferredSampleRate: Double = 44_100
    let audioFormatDescription: String = "test"

    private let levelSubject = CurrentValueSubject<Double, Never>(0)
    private let clip: RecordedAudioClip

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var cancelCallCount = 0

    var isRecording: Bool = false

    var levelPublisher: AnyPublisher<Double, Never> {
        levelSubject.eraseToAnyPublisher()
    }

    init(clip: RecordedAudioClip) {
        self.clip = clip
    }

    func startRecording() throws {
        startCallCount += 1
        isRecording = true
    }

    func stopRecording() throws -> RecordedAudioClip {
        stopCallCount += 1
        isRecording = false
        return clip
    }

    func cancelRecording() {
        cancelCallCount += 1
        isRecording = false
    }

    func removeClip(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func purgeStaleTemporaryFiles(olderThan age: TimeInterval) -> Int {
        0
    }
}

@MainActor
private final class FakeTextOutputCoordinator: TextOutputCoordinator {
    var insertionStrategy: String = "test"

    func currentSelectionSnapshot() -> FocusedSelectionSnapshot? {
        nil
    }

    func write(request: TextOutputRequest) async throws -> TextOutputResult {
        TextOutputResult(
            appName: request.focusContext.appName,
            bundleID: request.focusContext.bundleID,
            path: .accessibilitySelectionReplacement,
            usedFallback: false,
            operation: request.operation
        )
    }
}

private struct FixedContextDetector: ContextDetector {
    func currentSnapshot() -> ContextSnapshot {
        ContextSnapshot(
            focusContext: focusedAppContext(),
            rewriteAvailable: true,
            styleHint: "test"
        )
    }

    func focusedAppContext() -> FocusedAppContext {
        FocusedAppContext(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXTextArea",
            hasEditableTarget: true,
            strategyHint: "test"
        )
    }
}

private final class MemoryCredentialStoreForInteractionTests: ProviderCredentialStore {
    func loadAPIKey(for profileID: String) throws -> String? {
        nil
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {}

    func deleteAPIKey(for profileID: String) throws {}

    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool {
        false
    }
}

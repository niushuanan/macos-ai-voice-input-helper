import AppKit
import XCTest
@testable import PulseType

@MainActor
final class SessionStoreTests: XCTestCase {
    func testNewSessionClearsRuntimeArtifacts() {
        let store = SessionStore()
        let transcription = makeTranscription()
        let focusContext = makeFocusContext()
        let outputResult = makeOutputResult()

        store.startDictation()
        store.completeTranscription(result: transcription)
        store.markTranscribing(audioSummary: "1.2s captured at 44100Hz")
        store.markInserting(transcription: transcription, focusContext: focusContext)
        store.completeInsertion(outputResult: outputResult)

        XCTAssertEqual(store.phase, .idle)
        XCTAssertNotNil(store.latestTranscription)
        XCTAssertNotNil(store.latestOutputResult)

        store.startRewrite()

        XCTAssertEqual(store.phase, .listening)
        XCTAssertEqual(store.activeLane, .selectionRewrite)
        XCTAssertNil(store.latestTranscription)
        XCTAssertNil(store.latestFocusContext)
        XCTAssertNil(store.latestOutputResult)
        XCTAssertNil(store.errorMessage)
    }

    func testInvalidTransitionFromIdleIsIgnored() {
        let store = SessionStore()

        store.markInserting()

        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(store.statusMessage, "已准备，可通过快捷键开始语音会话。")
    }

    func testCancelClearsRuntimeAndMarksCancelled() {
        let store = SessionStore()

        store.startDictation()
        store.completeTranscription(result: makeTranscription())
        store.cancel()

        XCTAssertEqual(store.phase, .cancelled)
        XCTAssertNil(store.latestTranscription)
        XCTAssertNil(store.latestOutputResult)
        XCTAssertEqual(store.statusMessage, "本次会话已取消，目标应用内容未变化。")
    }

    func testRewriteFlowTransitionsToIdleOnCompletion() {
        let store = SessionStore()
        let transcription = makeTranscription()
        let focusContext = makeFocusContext()

        store.startRewrite()
        store.markTranscribing(audioSummary: "1.2s captured at 44100Hz")
        store.markRewriting(actionLabel: "Polish -> formal")
        store.markInserting(transcription: transcription, focusContext: focusContext)
        store.completeInsertion(outputResult: makeOutputResult())

        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(store.activeLane, .selectionRewrite)
        XCTAssertEqual(store.latestFocusContext?.bundleID, focusContext.bundleID)
        XCTAssertEqual(store.latestTranscription?.transcript, transcription.transcript)
    }

    func testClipboardOnlyInsertionUsesClipboardStatusMessage() {
        let store = SessionStore()
        let transcription = makeTranscription()
        let focusContext = makeFocusContext()

        store.startDictation()
        store.markTranscribing(audioSummary: "0.6 秒，44100Hz")
        store.markInserting(transcription: transcription, focusContext: focusContext)
        store.completeInsertion(
            outputResult: TextOutputResult(
                appName: "TextEdit",
                bundleID: "com.apple.TextEdit",
                path: .clipboardOnly,
                usedFallback: false,
                didInsertIntoEditor: false,
                operation: .insertText
            )
        )

        XCTAssertEqual(store.phase, .idle)
        XCTAssertTrue(store.statusMessage.contains("复制到剪贴板"))
    }

    func testListeningToTranscribingReflectsToggleStopStage() {
        let store = SessionStore()

        store.startDictation()
        store.markTranscribing(
            audioSummary: "0.6 秒，44100Hz",
            providerName: "OpenAI（官方）",
            modelName: "whisper-1"
        )

        XCTAssertEqual(store.phase, .transcribing)
        XCTAssertTrue(store.statusMessage.contains("whisper-1"))
    }

    func testPermissionGateDependsOnMicrophoneForSessionStart() {
        let blocked = PermissionSnapshot(
            microphone: .notRequested,
            accessibility: .granted
        )
        let micReadyAXMissing = PermissionSnapshot(
            microphone: .granted,
            accessibility: .denied
        )

        XCTAssertFalse(blocked.canStartVoiceSession)
        XCTAssertTrue(blocked.hasBlockingIssue)
        XCTAssertTrue(micReadyAXMissing.canStartVoiceSession)
        XCTAssertFalse(micReadyAXMissing.hasBlockingIssue)
    }

    private func makeTranscription() -> SpeechTranscriptionResult {
        SpeechTranscriptionResult(
            providerType: .openAI,
            providerName: "OpenAI Official",
            modelName: "whisper-1",
            transcript: "hello world"
        )
    }

    private func makeFocusContext() -> FocusedAppContext {
        FocusedAppContext(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXTextArea",
            hasEditableTarget: true,
            strategyHint: "AX 直写通常较稳定。"
        )
    }

    private func makeOutputResult() -> TextOutputResult {
        TextOutputResult(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            path: .accessibilitySelectionReplacement,
            usedFallback: false,
            didInsertIntoEditor: true,
            operation: .insertText
        )
    }
}

@MainActor
final class TextOutputCoordinatorTests: XCTestCase {
    func testEditableTargetUsesDirectInsertionPath() async throws {
        let coordinator = TestAccessibilityTextOutputCoordinator(
            contextDetector: StaticContextDetector(
                focusContext: FocusedAppContext(
                    appName: "TextEdit",
                    bundleID: "com.apple.TextEdit",
                    focusedRole: "AXTextArea",
                    hasEditableTarget: true,
                    strategyHint: "test"
                )
            )
        )

        let result = try await coordinator.write(
            request: TextOutputRequest(
                text: "hello",
                operation: .insertText,
                focusContext: FocusedAppContext(
                    appName: "TextEdit",
                    bundleID: "com.apple.TextEdit",
                    focusedRole: "AXTextArea",
                    hasEditableTarget: true,
                    strategyHint: "test"
                )
            )
        )

        XCTAssertEqual(result.path, .accessibilitySelectionReplacement)
        XCTAssertTrue(result.didInsertIntoEditor)
        XCTAssertEqual(coordinator.accessibilityWriteCount, 1)
        XCTAssertEqual(coordinator.pasteFallbackCount, 0)
    }

    func testNoEditableTargetReturnsClipboardOnly() async throws {
        let focusContext = FocusedAppContext(
            appName: "Finder",
            bundleID: "com.apple.finder",
            focusedRole: nil,
            hasEditableTarget: false,
            strategyHint: "test"
        )
        let coordinator = TestAccessibilityTextOutputCoordinator(
            contextDetector: StaticContextDetector(focusContext: focusContext)
        )

        let result = try await coordinator.write(
            request: TextOutputRequest(
                text: "hello",
                operation: .insertText,
                focusContext: focusContext
            )
        )

        XCTAssertEqual(result.path, .clipboardOnly)
        XCTAssertFalse(result.didInsertIntoEditor)
        XCTAssertEqual(coordinator.accessibilityWriteCount, 0)
        XCTAssertEqual(coordinator.pasteFallbackCount, 0)
    }

    func testMissingTargetAppFallsBackToClipboardOnlyInsteadOfError() async throws {
        let preferredFocusContext = FocusedAppContext(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXTextArea",
            hasEditableTarget: true,
            strategyHint: "test"
        )
        let coordinator = TestAccessibilityTextOutputCoordinator(
            contextDetector: StaticContextDetector(
                focusContext: FocusedAppContext(
                    appName: "PulseType",
                    bundleID: Bundle.main.bundleIdentifier ?? "tests.bundle",
                    focusedRole: nil,
                    hasEditableTarget: false,
                    strategyHint: "test"
                )
            )
        )
        coordinator.availableTargetBundleIDs = []

        let result = try await coordinator.write(
            request: TextOutputRequest(
                text: "hello",
                operation: .insertText,
                focusContext: preferredFocusContext,
                preferredTarget: WritebackTargetSnapshot(
                    appName: "TextEdit",
                    bundleID: "com.apple.TextEdit",
                    processIdentifier: 42
                )
            )
        )

        XCTAssertEqual(result.path, .clipboardOnly)
        XCTAssertEqual(result.appName, "TextEdit")
    }

    func testExternalTargetUsesPasteFallbackWhenAccessibilityPathFails() async throws {
        let focusContext = FocusedAppContext(
            appName: "Codex",
            bundleID: "com.openai.codex",
            focusedRole: nil,
            hasEditableTarget: false,
            strategyHint: "test"
        )
        let coordinator = TestAccessibilityTextOutputCoordinator(
            contextDetector: StaticContextDetector(focusContext: focusContext)
        )
        coordinator.accessibilityError = .noEditableTarget
        coordinator.forcedExternalTargetReady = true

        let result = try await coordinator.write(
            request: TextOutputRequest(
                text: "hello",
                operation: .insertText,
                focusContext: focusContext
            )
        )

        XCTAssertEqual(result.path, .pasteFallbackCommandV)
        XCTAssertTrue(result.didInsertIntoEditor)
        XCTAssertEqual(coordinator.accessibilityWriteCount, 1)
        XCTAssertEqual(coordinator.pasteFallbackCount, 1)
    }

    func testPasteFallbackUsesPreferredTargetProcessIdentifier() async throws {
        let focusContext = FocusedAppContext(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            focusedRole: nil,
            hasEditableTarget: false,
            strategyHint: "test"
        )
        let coordinator = TestAccessibilityTextOutputCoordinator(
            contextDetector: StaticContextDetector(focusContext: focusContext)
        )
        coordinator.accessibilityError = .noEditableTarget
        coordinator.forcedExternalTargetReady = true

        let result = try await coordinator.write(
            request: TextOutputRequest(
                text: "hello",
                operation: .insertText,
                focusContext: focusContext,
                preferredTarget: WritebackTargetSnapshot(
                    appName: "TextEdit",
                    bundleID: "com.apple.TextEdit",
                    processIdentifier: 3456
                )
            )
        )

        XCTAssertEqual(result.path, .pasteFallbackCommandV)
        XCTAssertEqual(coordinator.lastPasteTargetProcessIdentifier, 3456)
    }

    func testClipboardOnlyPathThrowsWhenClipboardUnavailable() async {
        let focusContext = FocusedAppContext(
            appName: "PulseType",
            bundleID: Bundle.main.bundleIdentifier ?? "tests.bundle",
            focusedRole: nil,
            hasEditableTarget: false,
            strategyHint: "test"
        )
        let coordinator = TestAccessibilityTextOutputCoordinator(
            contextDetector: StaticContextDetector(focusContext: focusContext)
        )
        coordinator.clipboardWriteSucceeded = false

        do {
            _ = try await coordinator.write(
                request: TextOutputRequest(
                    text: "hello",
                    operation: .insertText,
                    focusContext: focusContext
                )
            )
            XCTFail("Expected pasteboardUnavailable")
        } catch let error as TextOutputError {
            switch error {
            case .pasteboardUnavailable:
                break
            default:
                XCTFail("Expected pasteboardUnavailable, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private struct StaticContextDetector: ContextDetector {
    let focusContext: FocusedAppContext

    func currentSnapshot() -> ContextSnapshot {
        ContextSnapshot(
            focusContext: focusContext,
            rewriteAvailable: focusContext.hasEditableTarget,
            styleHint: "test"
        )
    }

    func focusedAppContext() -> FocusedAppContext {
        focusContext
    }
}

@MainActor
private final class TestAccessibilityTextOutputCoordinator: AccessibilityTextOutputCoordinator {
    var accessibilityWriteCount = 0
    var pasteFallbackCount = 0
    var lastPasteTargetProcessIdentifier: pid_t?
    var availableTargetBundleIDs: [String] = []
    var accessibilityError: TextOutputError?
    var forcedExternalTargetReady: Bool?
    var clipboardWriteSucceeded: Bool = true

    init(contextDetector: ContextDetector) {
        let diagnosticsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("text-output-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        super.init(
            logger: TextOutputLogger(diagnosticsDirectory: diagnosticsDirectory),
            contextDetector: contextDetector
        )
    }

    override func performAccessibilityPath(
        text: String,
        operation: TextOutputOperation
    ) throws {
        accessibilityWriteCount += 1
        if let accessibilityError {
            throw accessibilityError
        }
    }

    override func performPasteFallback(
        text: String,
        targetProcessIdentifier: pid_t?
    ) async throws {
        pasteFallbackCount += 1
        lastPasteTargetProcessIdentifier = targetProcessIdentifier
    }

    override func persistToClipboard(_ text: String) -> Bool {
        clipboardWriteSucceeded
    }

    override func runningApplications(withBundleIdentifier bundleID: String) -> [NSRunningApplication] {
        guard availableTargetBundleIDs.contains(bundleID) else {
            return []
        }
        return super.runningApplications(withBundleIdentifier: bundleID)
    }

    override func shouldAttemptExternalTargetWrite(
        preferredTarget: WritebackTargetSnapshot?,
        resolvedFocusContext: FocusedAppContext,
        fallbackFocusContext: FocusedAppContext,
        preferredTargetReachable: Bool
    ) async -> Bool {
        if let forcedExternalTargetReady {
            return forcedExternalTargetReady
        }
        return await super.shouldAttemptExternalTargetWrite(
            preferredTarget: preferredTarget,
            resolvedFocusContext: resolvedFocusContext,
            fallbackFocusContext: fallbackFocusContext,
            preferredTargetReachable: preferredTargetReachable
        )
    }
}

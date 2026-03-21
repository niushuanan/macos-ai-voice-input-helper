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
        XCTAssertEqual(store.statusMessage, "Ready for a keyboard-first voice session.")
    }

    func testCancelClearsRuntimeAndMarksCancelled() {
        let store = SessionStore()

        store.startDictation()
        store.completeTranscription(result: makeTranscription())
        store.cancel()

        XCTAssertEqual(store.phase, .cancelled)
        XCTAssertNil(store.latestTranscription)
        XCTAssertNil(store.latestOutputResult)
        XCTAssertEqual(store.statusMessage, "Session cancelled without changing the target app.")
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
            strategyHint: "AX direct insert is usually stable."
        )
    }

    private func makeOutputResult() -> TextOutputResult {
        TextOutputResult(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            path: .accessibilitySelectionReplacement,
            usedFallback: false,
            operation: .insertText
        )
    }
}

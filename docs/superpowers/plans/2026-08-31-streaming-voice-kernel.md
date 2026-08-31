# Streaming Voice Kernel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace PulseType's stop-then-upload dictation core with a streaming audio, realtime ASR, concurrent semantic editing, and automatic batch fallback kernel while preserving the current UI and final atomic writeback experience.

**Architecture:** A `VoiceInputKernel` actor owns one session and coordinates an `AVAudioEngine` chunk source, a Qwen realtime WebSocket session, a transcript ledger, and a bounded semantic editor. `InteractionCoordinator` retains product routing, history, and text output, but delegates recording/transcription to the kernel; the current batch provider remains the authoritative fallback.

**Tech Stack:** Swift 5.10 language mode, Xcode 26.6, macOS 14 deployment target, AVFoundation, Foundation `URLSessionWebSocketTask`, Swift Concurrency, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-31-streaming-voice-kernel-design.md`

## Global Constraints

- Preserve the existing SwiftUI visual style and shortcut interaction.
- Keep `PRODUCT_BUNDLE_IDENTIFIER = com.niushuanan.PulseType` and deployment target `macOS 14.0`.
- Qwen realtime is the default hot path; the current batch provider is the mandatory fallback.
- Do not write unstable ASR or LLM partials into arbitrary external apps; final writeback remains atomic.
- API keys remain in the app's existing credential store and must never appear in source, fixtures, logs, or docs.
- Every production behavior starts with a failing focused test and a confirmed RED result.
- User instruction overrides the skill's frequent-commit default: make no intermediate commits; create one final commit and one push only after all gates pass.

---

## File Map

**Create:**

- `Sources/Core/VoiceKernel/VoiceKernelTypes.swift` — provider-neutral contracts and results.
- `Sources/Core/VoiceKernel/TranscriptLedger.swift` — ordered committed/tentative transcript state.
- `Sources/Core/VoiceKernel/QwenRealtimeProtocol.swift` — endpoint resolution, JSON commands, and event parsing.
- `Sources/Core/VoiceKernel/QwenRealtimeASRSession.swift` — WebSocket transport and realtime provider session.
- `Sources/Core/VoiceKernel/StreamingAudioCaptureService.swift` — AVAudioEngine PCM stream plus fallback WAV.
- `Sources/Core/VoiceKernel/SemanticEditor.swift` — bounded concurrent LLM segment editing and fact guard.
- `Sources/Core/VoiceKernel/VoiceInputKernel.swift` — single-session actor and fallback handoff.
- `Tests/TranscriptLedgerTests.swift`
- `Tests/QwenRealtimeProtocolTests.swift`
- `Tests/QwenRealtimeASRSessionTests.swift`
- `Tests/QwenRealtimeLiveIntegrationTests.swift`
- `Tests/SemanticEditorTests.swift`
- `Tests/VoiceInputKernelTests.swift`

**Modify:**

- `Sources/App/AppModel.swift` — construct and inject the new kernel.
- `Sources/Core/Interaction/InteractionCoordinator.swift` — route start/stop/cancel through the new kernel.
- `Sources/Core/Session/SessionStore.swift` — accept provider-neutral realtime preview updates.
- `Tests/InteractionCoordinatorTests.swift` — prove final single writeback, fallback, and lane preservation.
- `PulseType.xcodeproj/project.pbxproj` — register the new source and test files.
- `PROJECT_CONTEXT.md` — refresh the new core structure and append the verified change.

---

### Task 1: Transcript contracts and ordered ledger

**Files:**

- Create: `Sources/Core/VoiceKernel/VoiceKernelTypes.swift`
- Create: `Sources/Core/VoiceKernel/TranscriptLedger.swift`
- Create: `Tests/TranscriptLedgerTests.swift`

**Interfaces:**

- Produces `StreamingTranscriptEvent`, `TranscriptSnapshot`, and `TranscriptLedger.apply(_:)` used by Tasks 2, 5, and 6.
- Does not depend on network, audio, UI, or providers.

- [x] **Step 1: Write failing ledger tests**

```swift
@MainActor
final class TranscriptLedgerTests: XCTestCase {
    func testCompletedItemsStayOrderedWhileTentativeTailChanges() {
        var ledger = TranscriptLedger()
        ledger.apply(.delta(itemID: "a", text: "第一"))
        ledger.apply(.completed(itemID: "a", transcript: "第一句。"))
        ledger.apply(.delta(itemID: "b", text: "第二"))
        XCTAssertEqual(ledger.snapshot.committedText, "第一句。")
        XCTAssertEqual(ledger.snapshot.tentativeText, "第二")

        ledger.apply(.delta(itemID: "b", text: "第二句"))
        XCTAssertEqual(ledger.snapshot.previewText, "第一句。第二句")
    }

    func testCompletedTranscriptReplacesDeltasWithoutDuplication() {
        var ledger = TranscriptLedger()
        ledger.apply(.delta(itemID: "a", text: "你好"))
        ledger.apply(.delta(itemID: "a", text: "你好世界"))
        ledger.apply(.completed(itemID: "a", transcript: "你好，世界。"))
        XCTAssertEqual(ledger.snapshot.finalText, "你好，世界。")
    }
}
```

- [x] **Step 2: Run focused tests and confirm RED**

Run:

```bash
PULSETYPE_ALLOW_DEBUG_RUNTIME=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PulseType.xcodeproj -scheme PulseType -destination 'platform=macOS' test -only-testing:PulseTypeTests/TranscriptLedgerTests
```

Expected: compile failure because the new types do not exist.

- [x] **Step 3: Implement minimal provider-neutral types and ledger**

Use these signatures:

```swift
enum StreamingTranscriptEvent: Equatable, Sendable {
    case sessionReady
    case speechStarted(itemID: String?)
    case delta(itemID: String, confirmedText: String, tentativeText: String)
    case completed(itemID: String, transcript: String)
    case sessionFinished
}

struct TranscriptSnapshot: Equatable, Sendable {
    let committedText: String
    let tentativeText: String
    var previewText: String { committedText + tentativeText }
    var finalText: String { committedText + tentativeText }
}

struct TranscriptLedger: Sendable {
    private(set) var snapshot: TranscriptSnapshot
    mutating func apply(_ event: StreamingTranscriptEvent)
}
```

Maintain item insertion order, store exactly one authoritative completed string per item, and trim only boundary whitespace during composition.

- [x] **Step 4: Run focused tests and confirm GREEN**

Run the Step 2 command. Expected: all `TranscriptLedgerTests` pass.

---

### Task 2: Qwen realtime endpoint, commands, and tolerant event parser

**Files:**

- Create: `Sources/Core/VoiceKernel/QwenRealtimeProtocol.swift`
- Create: `Tests/QwenRealtimeProtocolTests.swift`

**Interfaces:**

- Consumes `StreamingTranscriptEvent` from Task 1.
- Produces `QwenRealtimeEndpointResolver`, `QwenRealtimeCommandEncoder`, and `QwenRealtimeEventParser` used by Task 3.

- [x] **Step 1: Write failing protocol tests**

```swift
final class QwenRealtimeProtocolTests: XCTestCase {
    func testLegacyDashScopeHTTPURLBecomesRealtimeWebSocketURL() throws {
        let url = try QwenRealtimeEndpointResolver.resolve(
            baseURL: URL(string: "https://dashscope.aliyuncs.com")!,
            model: "qwen3-asr-flash-realtime"
        )
        XCTAssertEqual(url.absoluteString, "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime")
    }

    func testCompletedEventParsesAuthoritativeTranscript() throws {
        let data = Data(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item-1","transcript":"你好，世界。"}"#.utf8)
        XCTAssertEqual(
            try QwenRealtimeEventParser.parse(data),
            .completed(itemID: "item-1", transcript: "你好，世界。")
        )
    }

    func testServerErrorThrowsActionableFailure() {
        let data = Data(#"{"type":"error","error":{"code":"invalid_api_key","message":"bad key"}}"#.utf8)
        XCTAssertThrowsError(try QwenRealtimeEventParser.parse(data))
    }
}
```

- [x] **Step 2: Run focused tests and confirm RED**

Use the Task 1 command with `-only-testing:PulseTypeTests/QwenRealtimeProtocolTests`. Expected: missing type compile failure.

- [x] **Step 3: Implement endpoint and protocol helpers**

Rules:

- Convert `http` to `ws` and `https` to `wss`.
- Preserve workspace-specific hosts.
- Replace any existing path with `/api-ws/v1/realtime`.
- Replace existing `model` query value without duplicating it.
- Session update uses PCM, 16kHz, `language = zh`, server VAD threshold `0.0`, silence `400ms`, and context corpus capped before encoding.
- Append encodes each chunk independently as Base64.
- Parser accepts transcript fragments from `delta`, `text`, or `transcript` fields and ignores known lifecycle events that do not change transcript state.
- Provider `error` events throw `VoiceKernelFailure.provider` with code and sanitized message.

- [x] **Step 4: Run focused tests and confirm GREEN**

Run the Task 2 focused command. Expected: all protocol tests pass.

---

### Task 3: WebSocket transport and Qwen realtime session

**Files:**

- Create: `Sources/Core/VoiceKernel/QwenRealtimeASRSession.swift`
- Modify: `Tests/QwenRealtimeProtocolTests.swift`

**Interfaces:**

- Consumes Task 1 events and Task 2 protocol helpers.
- Produces `RealtimeASRSession` and `QwenRealtimeASRSession` used by Task 6.

- [x] **Step 1: Add failing ordering and cancellation tests using an in-memory transport**

```swift
func testFinishWaitsUntilQueuedAudioWasSent() async throws {
    let transport = RecordingWebSocketTransport()
    let session = QwenRealtimeASRSession(transport: transport, configuration: fixtureConfiguration)
    try await session.start(context: fixtureContext)
    try await session.append(.init(sequence: 0, pcmData: Data([1, 2]), duration: 0.05))
    try await session.finish()
    XCTAssertEqual(transport.sentEventTypes.suffix(2), ["input_audio_buffer.append", "session.finish"])
}
```

Also prove that `cancel()` closes transport and that a server error terminates the event stream once.

- [x] **Step 2: Run the focused test and confirm RED**

Expected: missing realtime session and transport protocols.

- [x] **Step 3: Implement transport abstraction and session actor**

```swift
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
```

The production transport wraps `URLSessionWebSocketTask`, waits for the real WebSocket open callback, and converts UTF-8 JSON payloads to text frames. The session owns one receive loop, serializes sends inside the actor, yields parsed events, and enforces a finite final-event timeout. It must never log authorization headers or raw transcript JSON.

- [x] **Step 4: Run Tasks 1–3 tests and confirm GREEN**

Run both `TranscriptLedgerTests` and `QwenRealtimeProtocolTests` with two `-only-testing` arguments.

---

### Task 4: Streaming audio capture with bounded delivery and fallback WAV

**Files:**

- Create: `Sources/Core/VoiceKernel/StreamingAudioCaptureService.swift`
- Modify: `Tests/AudioCaptureServiceDurationTests.swift`

**Interfaces:**

- Produces `StreamingAudioCaptureService`, `VoiceAudioChunk`, and final `RecordedAudioClip` used by Task 6.
- Preserves `levelPublisher`, temporary-file cleanup, and duration behavior used by existing UI.

- [x] **Step 1: Write failing deterministic buffer tests**

Add tests around a pure `PCMChunkFramer`:

```swift
func testFramerEmitsMonotonicSequencesAndExactRemainder() {
    var framer = PCMChunkFramer(bytesPerChunk: 4, bytesPerSecond: 8)
    XCTAssertEqual(framer.append(Data([0, 1, 2])), [])
    let first = framer.append(Data([3, 4, 5, 6, 7]))
    XCTAssertEqual(first.map(\.sequence), [0, 1])
    XCTAssertEqual(first.map(\.duration), [0.5, 0.5])
    XCTAssertEqual(framer.finish(), [])
}
```

Add a test that queue overflow returns `.overflow` rather than silently dropping a chunk.

- [x] **Step 2: Run focused audio tests and confirm RED**

Expected: missing framer and capture types.

- [x] **Step 3: Implement the framer and AVAudioEngine capture service**

- Use `AVAudioConverter` to convert microphone format to 16kHz signed-interleaved PCM.
- Process conversion, WAV writes, framing, and stream yield on one dedicated serial dispatch queue.
- Use a bounded stream capacity representing at least four seconds of audio.
- Surface overflow as `VoiceKernelFailure.audioBackpressure` and keep the WAV valid for fallback.
- Stop must synchronously drain the serial queue before returning the clip.
- Cancel removes the active temporary file and finishes the chunk stream.

- [x] **Step 4: Run audio tests and confirm GREEN**

Run `AudioCaptureServiceDurationTests` plus the new framer test class.

---

### Task 5: Concurrent semantic editor with source validation

**Files:**

- Create: `Sources/Core/VoiceKernel/SemanticEditor.swift`
- Create: `Tests/SemanticEditorTests.swift`

**Interfaces:**

- Consumes current `TextGenerationProvider`, app/system prompt, dictionary terms, and committed transcript segments.
- Produces `SemanticEditResult` for Task 6.

- [x] **Step 1: Write failing fact-guard and stale-revision tests**

```swift
func testFactGuardRejectsChangedNumbersEnglishTokensAndNegation() {
    let source = "订单 AB-129 不要改成 130"
    XCTAssertFalse(SemanticFactGuard(source: source, dictionaryTerms: []).accepts("订单 AB-128 要改成 130"))
    XCTAssertTrue(SemanticFactGuard(source: source, dictionaryTerms: []).accepts("订单 AB-129，不要改成 130。"))
}

func testOlderRevisionCannotReplaceNewerSegment() async {
    let editor = SemanticEditor(provider: ControlledTextProvider())
    let old = await editor.submit(segmentID: "s", revision: 1, source: "旧文本", context: fixture)
    _ = await editor.submit(segmentID: "s", revision: 2, source: "新文本", context: fixture)
    XCTAssertFalse(await editor.isCurrent(old))
}
```

- [x] **Step 2: Run focused semantic tests and confirm RED**

Expected: missing semantic editor types.

- [x] **Step 3: Implement bounded editor and conservative prompt**

- Cap concurrent provider calls at two.
- Store latest revision per segment and discard stale completions.
- Prompt says the model is a transcript editor, must preserve meaning/order, may return the input unchanged, and must never answer or execute the content.
- Validate digits, ASCII identifiers, URLs/emails/paths, negative tokens, and matched dictionary terms.
- Return source text on empty output, provider error, timeout, stale revision, or fact-guard failure.
- Expose `finalize(deadline:)` so Task 6 can wait only for the configured stop budget.

- [x] **Step 4: Run semantic tests and confirm GREEN**

Run `SemanticEditorTests` and existing rewrite provider tests.

---

### Task 6: VoiceInputKernel session actor and batch fallback handoff

**Files:**

- Create: `Sources/Core/VoiceKernel/VoiceInputKernel.swift`
- Create: `Tests/VoiceInputKernelTests.swift`

**Interfaces:**

- Consumes realtime ASR, streaming capture, transcript ledger, semantic editor, and logger.
- Produces `updates: AsyncStream<VoiceKernelUpdate>` and `stop() async -> VoiceKernelResult` for Task 7.

- [x] **Step 1: Write failing orchestration tests with fake capture/provider/editor**

Required behaviors:

```swift
func testNormalStopReturnsEditedSegmentsInOrder() async throws
func testRealtimeFailureReturnsFallbackClipExactlyOnce() async throws
func testStopDrainsAudioBeforeFinishingProvider() async throws
func testCancelPreventsLateEventsFromProducingResult() async throws
func testSecondStartWhileActiveIsRejected() async throws
```

Assertions must inspect user-visible result and operation order, not implementation call counts alone.

- [x] **Step 2: Run focused kernel tests and confirm RED**

Expected: missing `VoiceInputKernel`.

- [x] **Step 3: Implement the actor state machine**

```swift
actor VoiceInputKernel {
    func start(context: VoiceSessionContext) async throws -> AsyncStream<VoiceKernelUpdate>
    func stop() async throws -> VoiceKernelResult
    func cancel() async
}
```

- Start capture and realtime connection concurrently; buffer early chunks until connection is ready.
- Consume ASR events into `TranscriptLedger` and emit previews.
- Submit completed segments to `SemanticEditor` immediately.
- On stop: stop/drain capture, send all chunks, finish realtime, finalize semantic work, then return one final result.
- On realtime failure: return `.batchFallback(clip, reason)` without calling the batch provider internally, so `InteractionCoordinator` remains the single owner of provider configuration and retry policy.
- Session ID guards every callback.

- [x] **Step 4: Run kernel tests and confirm GREEN**

Run all four new test classes.

---

### Task 7: Integrate the kernel into all voice lanes without changing UI style

**Files:**

- Modify: `Sources/App/AppModel.swift`
- Modify: `Sources/Core/Interaction/InteractionCoordinator.swift`
- Modify: `Sources/Core/Session/SessionStore.swift`
- Modify: `Tests/InteractionCoordinatorTests.swift`

**Interfaces:**

- Consumes `VoiceInputKernel` from Task 6.
- Preserves existing `handleStartInput`, `handleStopInput`, `handleCancelInput`, lane routing, history, Agent V4, and `TextOutputCoordinator` public behavior.

- [x] **Step 1: Add failing coordinator integration tests**

Prove:

- Direct dictation previews update the HUD but call external writeback once with final text.
- Realtime result bypasses the old batch provider.
- Fallback result invokes the old batch provider with the kernel's clip.
- Selection rewrite and brainstorm receive the same final transcript and continue through their existing downstream routes.
- A late update after cancellation does not write or append history.
- Long direct dictation no longer invokes the old length-based whole-document post-process route after the kernel already produced semantic text.

- [x] **Step 2: Run coordinator tests and confirm RED**

Expected: fixture cannot inject the new kernel and current flow still starts batch transcription only after stop.

- [x] **Step 3: Replace recording/transcription ownership**

- Capture `DictationWritebackTarget` and context before `kernel.start`.
- Map kernel updates to existing SessionStore phases and preview text.
- For `.realtimeFinal`, construct `SpeechTranscriptionResult` and call existing lane-specific downstream methods.
- For `.batchFallback`, call the existing `startTranscription(for:)` path exactly once.
- Remove normal direct-lane reliance on `DictationTextProcessingPolicy.shouldUseModel(text:)`; the fallback batch route may retain current post-processing until it is also supplied through `SemanticEditor`.
- Keep final atomic writeback and clipboard recovery unchanged.

- [x] **Step 4: Run coordinator and session tests and confirm GREEN**

Run `InteractionCoordinatorTests`, `InteractionCoordinatorV4RoutingTests`, and `SessionStoreTests`.

---

### Task 8: Observability, build configuration, and focused regression

**Files:**

- Modify: `Sources/Core/Interaction/InteractionCoordinator.swift`.
- Modify: generated `PulseType.xcodeproj/project.pbxproj` to register the new groups and files.
- Modify: new and existing tests from Tasks 1–7.

**Interfaces:**

- Consumes kernel updates and metrics.
- Produces stage logs without transcript/audio content.

- [x] **Step 1: Add failing coordinator observability assertions**

The test emits a realtime preview and completed segment, then asserts stage and length metadata exist while item ID and transcript body never enter the log.

- [x] **Step 2: Run the logger test and confirm RED**

Expected: realtime first-delta and segment-completed stages are missing.

- [x] **Step 3: Add key realtime stage logs**

Record `voice.stop`, `asr.first_delta`, `asr.segment.completed`, realtime success, fallback activation, and fallback handoff. Reuse existing batch/final-write stages. Log lengths/counts only, never body text.

- [x] **Step 4: Run the equivalent focused regression set**

The skill script is bound to another historical repository path, so run the equivalent Xcode `-only-testing` set in this workspace. Include all new VoiceKernel tests, InteractionCoordinator tests, SessionStore tests, provider tests, and audio duration tests.

- [x] **Step 5: Run a clean Debug build**

```bash
PULSETYPE_ALLOW_DEBUG_RUNTIME=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PulseType.xcodeproj -scheme PulseType -configuration Debug -destination 'platform=macOS' build
```

Expected: `BUILD SUCCEEDED` with no new warnings from VoiceKernel files.

---

### Task 9: Real provider and cross-app product validation

**Files:**

- No source edit unless a reproduced failure first receives a failing regression test.
- Read diagnostics from the existing local PulseType diagnostics directory.

**Interfaces:**

- Validates the full user path rather than isolated APIs.

- [x] **Step 1: Install an unsigned/local Debug build without committing**

Use the existing install script with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, preserving bundle identifier and permissions.

- [ ] **Step 2: Open PulseType and run real short/medium/long dictation**

Use the existing configured Qwen and DeepSeek credentials without displaying them. Record trace IDs for approximately 5, 30, and 60+ second Chinese inputs.

- [ ] **Step 3: Verify actual destinations**

Verify final atomic writeback in TextEdit, the current in-app browser/editor, Codex, and one Electron/rich-text target available locally. Confirm no duplicate text, missing prefix, wrong target, or clipboard corruption.

- [x] **Step 4: Verify fallback**

Use an injectable test transport or a safe local connection-failure switch rather than changing credentials. Confirm the WAV batch fallback yields final text and removes the temporary file after success.

- [ ] **Step 5: Measure acceptance metrics from logs**

For each trace calculate first-delta latency, stop-to-final, semantic wait, stop-to-write, chunks sent, and fallback reason. Compare 5/30/60+ second stop latency; do not claim the length-independence target without real traces.

---

### Task 10: Context update, final gate, one commit, one push, and open installed app

**Files:**

- Modify: `PROJECT_CONTEXT.md`
- Include all source, test, spec, plan, and generated project files intentionally changed by this work.

- [x] **Step 1: Update project context using `project-context-update`**

Refresh sections 1–3 because the core architecture and key entry points changed. Append a timestamped section listing actual files, behavior, rationale, affected modules, and real validation evidence.

- [x] **Step 2: Run verification-before-completion and code review skills**

Audit every acceptance requirement against current files, test output, build output, traces, installed bundle metadata, and real writeback results. Fix any issue through a new RED/GREEN cycle.

- [ ] **Step 3: Run the final release gate and create exactly one new commit/push**

Use `pulsetype-auto-ship` and the repository command below with the exact final file list:

```bash
scripts/auto-ship.sh \
  --message "feat: rebuild the voice input kernel for realtime dictation" \
  --files \
  Sources/Core/VoiceKernel/VoiceKernelTypes.swift \
  Sources/Core/VoiceKernel/TranscriptLedger.swift \
  Sources/Core/VoiceKernel/QwenRealtimeProtocol.swift \
  Sources/Core/VoiceKernel/QwenRealtimeASRSession.swift \
  Sources/Core/VoiceKernel/StreamingAudioCaptureService.swift \
  Sources/Core/VoiceKernel/SemanticEditor.swift \
  Sources/Core/VoiceKernel/VoiceInputKernel.swift \
  Sources/App/AppModel.swift \
  Sources/Core/Interaction/InteractionCoordinator.swift \
  Sources/Core/Session/SessionStore.swift \
  Tests/TranscriptLedgerTests.swift \
  Tests/QwenRealtimeProtocolTests.swift \
  Tests/QwenRealtimeASRSessionTests.swift \
  Tests/QwenRealtimeLiveIntegrationTests.swift \
  Tests/SemanticEditorTests.swift \
  Tests/VoiceInputKernelTests.swift \
  Tests/AudioCaptureServiceDurationTests.swift \
  Tests/InteractionCoordinatorTests.swift \
  PulseType.xcodeproj/project.pbxproj \
  docs/superpowers/specs/2026-08-31-streaming-voice-kernel-design.md \
  docs/superpowers/plans/2026-08-31-streaming-voice-kernel.md \
  PROJECT_CONTEXT.md \
  --with-test
```

Before running it, compare this enumerated list with `git diff --name-only`: remove any listed file that remained unchanged, and stop if an unlisted task file exists. This is the only commit and only push created by this task.

- [ ] **Step 4: Verify installed runtime**

Confirm `/Applications/PulseType.app` has bundle ID `com.niushuanan.PulseType`, launch it, confirm the process is running, and perform one final real dictation after installation.

- [ ] **Step 5: Confirm remote and worktree state**

Verify the new commit is `HEAD`, `origin/codex/magician-agent-v2` resolves to the same SHA, and `git status --short` contains no task residue.

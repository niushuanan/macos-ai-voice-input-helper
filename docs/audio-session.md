# Audio Session Design

## Scope of this round

This round focuses only on local capture and session feel:

- wake shortcut starts recording
- real-time listening feedback is visible while speaking
- stop shortcut (or wake shortcut when already listening) ends recording
- a pending audio clip is produced for the next transcribe stage
- cancel discards the current capture

Provider API calls are intentionally out of scope here.

## Recording pipeline

Runtime flow:

1. User triggers wake (`Control + Option + Space`) from `idle` / `cancelled` / `error`.
2. `InteractionCoordinator` checks microphone permission.
3. `AVAudioRecorderCaptureService.startRecording()` starts local AAC mono capture.
4. Session phase moves to `listening`.
5. Recorder level updates stream into `SessionStore.listeningLevel` every 50ms.
6. User triggers stop (same wake key while listening, or dedicated stop key).
7. `stopRecording()` finalizes a `.m4a` clip and returns `RecordedAudioClip`.
8. Session phase moves to `transcribing` with `pendingClip` attached.

Cancel path:

- If recording is active, cancel stops recording and removes the active temp file.
- If a pending clip exists, cancel removes it and transitions to `cancelled`.

## Temporary audio storage

Storage location:

- `~/Library/Application Support/PulseType/TemporaryAudio`

File format and naming:

- AAC mono `.m4a`
- filename pattern: `clip-<iso-timestamp>-<short-uuid>.m4a`

Lifecycle policy:

- active clip: exists only during an active recording
- pending clip: exists after stop and before downstream handling
- removed on:
  - cancel
  - session completion
  - manual reset
  - start of a new session (old pending clip cleanup)
- stale cleanup:
  - app startup purges temp clips older than 24 hours

Goal:

- ensure temp audio does not accumulate during normal use
- keep just enough local artifact for the immediate next processing stage

## Failure handling

Current explicit failure states:

- microphone permission missing: session start blocked with clear message
- recorder start failure: phase moves to `error` with reason
- recorder stop failure: phase moves to `error` with reason
- user cancel: phase moves to `cancelled`, no clip kept

## Listening feedback design

Candidate options reviewed:

- menu bar live level meter (selected)
- persistent floating listening chip (parked)

Selected implementation:

- tiny dynamic level pips in menu bar while `listening`
- wider input-level strip in command deck status card
- existing HUD remains short and phase-oriented, not always-on

This keeps the product responsive and “alive” without stealing focus.

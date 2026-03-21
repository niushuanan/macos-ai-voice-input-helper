# Architecture

## Facts today

The repository already contains these concrete building blocks:

- `Sources/App`
  - `PulseTypeApp.swift`: SwiftUI app entry using `MenuBarExtra`
  - `AppDelegate.swift`: helper-app activation policy
  - `AppModel.swift`: composition root for core services
- `Sources/Core`
  - `Session`: state machine and lane definitions
  - `Hotkey`: current shortcut plan
  - `Audio`: native `AVAudioRecorder` capture service with live level metering
  - `Speech`: provider protocol, provider registry, OpenAI transcription client, provider settings
  - `Security`: Keychain-backed API key credential store
  - `TextOutput`: insertion abstraction placeholder
  - `Context`: frontmost-app and style context placeholder
  - `Permissions`: permission snapshot placeholder
  - `Storage`: local data root model
  - `Diagnostics`: local diagnostics summary
- `Sources/UI`
  - menu bar status icon
  - menu bar panel
  - settings surface

## Product-shaping constraints

- The app remains a helper app instead of a system input method.
- The interaction starts from keyboard shortcuts, not from a text field.
- Dictation and rewrite are separate lanes inside one session model.
- Provider calls are remote in phase 1 and phase 2, but user data stays local.

## Runtime design

### App lifecycle

Current:

- launch into a menu bar extra
- keep the app out of the Dock via helper-app behavior
- expose settings and quit actions from the menu bar panel

Planned:

- register global shortcuts at launch
- initialize permissions and diagnostics observers
- keep lightweight session state hot even when the settings window is closed

### Keyboard interaction skeleton (v1)

Selected model: `tap-tap dual-lane session`

- Wake:
  - `Control + Option + Space`
  - if app state is `idle`, `cancelled`, or `error`, start a new session
- Stop:
  - tap `Control + Option + Space` again when in `listening`
  - or use dedicated stop shortcut `Control + Option + Return`
  - this transitions to `transcribing`
- Cancel:
  - `Control + Option + Escape` at any active phase
  - this transitions to `cancelled`
- Lane split:
  - default wake -> `directDictation`
  - wake with rewrite modifier plus valid selection -> `selectionRewrite`
- Status cue:
  - menu bar icon reflects phase in real time
  - a short non-blocking HUD pulse appears on phase change

Current default keymap:

- Wake and start: `Control + Option + Space`
- Stop and submit: `Control + Option + Return`
- Cancel session: `Control + Option + Escape`

Implementation notes:

- Registered through the `KeyboardShortcuts` package.
- Routed through `InteractionCoordinator` into `SessionStore`.
- Session cancel is independent from app quit.

### Session model

The central state machine lives in `Sources/Core/Session/SessionStore.swift`.

Current states:

- `idle`
- `listening`
- `transcribing`
- `rewriting`
- `inserting`
- `cancelled`
- `error`

Design intent:

- one authoritative session phase for the whole app
- one lane selector that tracks `directDictation` versus `selectionRewrite`
- explicit cancel and error paths so text insertion never happens by accident

Transition rhythm in v1:

- Wake -> `listening`
- Stop -> `transcribing`
- Rewrite branch (if needed) -> `rewriting`
- Apply output -> `inserting`
- Finish -> `idle`
- Cancel from active phases -> `cancelled` -> `idle`

### Interaction lanes

Lane 1: direct dictation

- capture speech
- transcribe or transform
- insert new text into the focused app

Lane 2: selection rewrite

- detect selection context
- capture speech as rewrite intent
- transform selected text
- replace the original selection safely

## Service boundaries

### Hotkey

Responsibility:

- global wake and cancel registration
- shortcut conflict reporting

Dependency rule:

- may drive `SessionStore`
- must not know provider-specific request shaping

### AudioCapture

Responsibility:

- microphone session setup
- record a session clip and hand it to the speech layer
- publish low-latency listening level for lightweight UI feedback

Dependency rule:

- may publish captured audio artifacts
- must not own provider prompts or insertion logic

Current implementation:

- `AVAudioRecorderCaptureService` records AAC mono `.m4a` clips.
- Input level updates are published every 50ms for UI feedback.
- The active clip is tracked as `pendingClip` in `SessionStore` after stop.
- Temp clip lifecycle is tied to session controls:
  - cancel: delete active or pending clip
  - complete/reset/new session start: delete older pending clip
  - app launch: purge stale temp files older than 24 hours

### SpeechProvider

Responsibility:

- convert audio and context into a provider request
- normalize provider output into app-level result objects

Dependency rule:

- may depend on user key storage
- must not talk directly to the UI layer

Current implementation:

- `SpeechTranscriptionProvider` defines the provider contract.
- `SpeechProviderRegistry` resolves the selected provider.
- `OpenAITranscriptionProvider` uploads `.m4a` audio with multipart requests.
- `ProviderSettingsStore` manages selected provider and model.
- API keys are loaded from Keychain through `ProviderCredentialStore`.

### TextOutput

Responsibility:

- return text to the frontmost app
- handle replace versus insert behavior

Dependency rule:

- may depend on Accessibility and pasteboard bridges
- must respect cancel state before mutating the target app

### ContextDetection

Responsibility:

- identify frontmost app category
- detect whether selection rewrite is likely available
- provide style hints for scene-tuned presets

Dependency rule:

- may inspect frontmost-app metadata
- must remain heuristic and explainable in v1

### Permissions

Responsibility:

- query microphone and Accessibility readiness
- drive guidance UI when a needed capability is blocked

Current model:

- microphone permission is required for session start
- Accessibility permission is required for selection rewrite and insertion bridge
- global hotkeys do not require additional permission with Carbon-based registration

### LocalStore

Responsibility:

- define local paths for history, diagnostics, and configuration
- own migration-safe storage layout

### Settings

Responsibility:

- user provider keys
- hotkey configuration
- preset and storage preferences

Current implementation:

- provider picker
- model text input with validation
- API key save/delete using Keychain-backed store

### Diagnostics

Responsibility:

- collect local traces for startup, session flow, and provider failures
- avoid leaking secrets into logs

## Data boundaries

Persist locally by default:

- session history
- rewrite history
- settings and preferences
- diagnostics metadata

Do not persist in plain text unless there is a clear product reason:

- provider secrets
- temporary raw audio artifacts beyond the active session lifecycle

## Dependency direction

Preferred dependency flow:

`UI -> AppModel -> Core services -> system APIs / provider adapters / storage`

Rules:

- UI reads state and triggers intents
- `SessionStore` is the single source of truth for session phase
- provider adapters should stay behind the `SpeechProvider` abstraction
- storage and diagnostics should be usable without UI code

## Current gaps

These are known missing pieces, not accidents:

- no insertion bridge yet
- no full first-launch permission walkthrough yet
- no waveform-grade visualizer; current listening feedback is a minimal level meter

## Known system limits

- global shortcuts may collide with user or system-level bindings
- Accessibility capabilities vary by target app and app version
- permission changes can lag until app focus returns from System Settings

## Open questions

- Which hotkey pair gives the best balance of reach and conflict avoidance?
- Should selection rewrite rely on Accessibility first, pasteboard fallback
  second, or the reverse?
- Where should provider keys live: Keychain only, or Keychain plus local
  metadata for multi-provider configs?

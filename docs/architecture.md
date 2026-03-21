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
  - `History`: local session history persistence with delete controls
  - `Security`: Keychain-backed API key credential store
  - `TextOutput`: insertion abstraction placeholder
  - `Context`: frontmost-app detection plus per-app scene policy store
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
  - wake with valid text selection -> `selectionRewrite`
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
- capture speech as rewrite command
- map command to action template (`translate`, `polish`, `condense`, `structure`, or fallback custom)
- generate rewritten text with selected rewrite provider/model
- replace the original selection safely

### Selection rewrite runtime chain (Prompt 7)

The current rewrite lane is selection-aware and action-aware:

1. Wake hotkey is pressed.
2. If selected text exists in the focused app, lane resolves to `selectionRewrite`; otherwise lane resolves to `directDictation`.
3. User speech is transcribed.
4. Transcribed command is parsed into `RewriteIntent`.
5. Prompt template is assembled from:
   - app context (`appName`, `bundleID`)
   - spoken command
   - selected text
   - normalized action instruction
6. Rewrite provider generates replacement text.
7. Text output layer overwrites selected text (`replaceSelectedText` operation).
8. If overwrite fails, failure is surfaced with explicit error messaging.

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
- `SpeechProviderRegistry` resolves provider implementation by `ProviderType`.
- `OpenAITranscriptionProvider` supports both:
  - `OpenAI Official`
  - `OpenAI-Compatible`
- `ProviderSettingsStore` is profile-based:
  - role binding for transcription vs rewrite
  - profile metadata (name/type/base URL/model/enable state)
- API keys are loaded from Keychain per profile ID via `ProviderCredentialStore`.

### RewriteProvider / TextGenerationProvider

Responsibility:

- map spoken rewrite commands into maintainable action intents
- build structured prompts for selection-based rewriting
- call text-generation backend and normalize result

Current implementation:

- `RewriteProvider` protocol for selection rewrite contracts
- `TextGenerationProvider` protocol for model text generation contracts
- `OpenAITextGenerationProvider` supports OpenAI and compatible endpoints for `/v1/chat/completions`
- `OpenAIRewriteProvider` handles intent parsing + prompt templating + generation call
- `RewriteProviderRegistry` resolves rewrite provider by `ProviderType`

### TextOutput

Responsibility:

- return text to the frontmost app
- handle replace versus insert behavior

Dependency rule:

- may depend on Accessibility and pasteboard bridges
- must respect cancel state before mutating the target app

Current implementation:

- output operation split:
  - `insertText`
  - `replaceSelectedText`
- main path:
  - AX focused-element direct replacement
- fallback path:
  - explicit pasteboard + `Command + V`
- both paths are logged in diagnostics:
  - `Diagnostics/text-output.log`
- rewrite lane uses `replaceSelectedText` explicitly; it is not aliased to insert flow

### ContextDetection

Responsibility:

- identify frontmost app category
- detect whether selection rewrite is likely available
- provide style hints for scene-tuned presets

Dependency rule:

- may inspect frontmost-app metadata
- must remain heuristic and explainable in v1

Current implementation:

- captures:
  - app name
  - bundle id
  - focused role (if available)
  - editable-target boolean
  - write strategy hint
- source:
  - `NSWorkspace` + AX focused element query

### AppScenePolicy

Responsibility:

- store user-editable per-app behavior policy
- expose deterministic defaults when no custom policy is stored
- drive lane preference and rewrite style bias from app context

Current implementation:

- policy fields:
  - `outputBias` (`neutral`, `formal`, `casual`, `structured`)
  - `preferSelectionRewrite` (`Bool`)
- runtime usage:
  - lane resolver can prefer rewrite lane when selection exists
  - rewrite parser can map generic polish commands using the app policy bias
- settings surface:
  - edit focused-app policy
  - list and edit saved custom app policies
  - remove custom policies

### History

Responsibility:

- persist local session records for dictation and rewrite lanes
- provide user-manageable delete operations
- retain provider and result metadata for diagnostics transparency

Current implementation:

- file path:
  - `History/session-history-v1.json`
- fields include:
  - time
  - lane mode
  - frontmost app info
  - input/output text
  - provider metadata
  - success/failed/cancelled state
- settings surface:
  - latest 20 entries preview
  - per-entry delete
  - full clear action

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

- role binding pickers:
  - transcription provider profile
  - rewrite provider profile
- profile editor:
  - provider type
  - name
  - enable/disable
  - base URL (optional for compatible type)
  - transcription model and rewrite model
- API key save/delete using profile-scoped Keychain entries
- local history panel with:
  - app/mode/status filters
  - focused-app-only toggle
  - per-entry delete and full clear
- app scene policy panel with:
  - focused-app quick edit
  - saved policy list and inline controls

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

See [local-history-and-scene-policy.md](local-history-and-scene-policy.md)
for concrete storage keys and policy schema details.

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

- rewrite command parser is rule-based and still limited in language coverage
- no dedicated rewrite action palette UI yet (voice command only)
- no per-profile provider connection test button yet
- no vendor-specific advanced params (temperature/top_p/etc.) in settings yet
- no full first-launch permission walkthrough yet
- no waveform-grade visualizer; current listening feedback is a minimal level meter
- AX replacement compatibility still needs broader validation across third-party editors

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

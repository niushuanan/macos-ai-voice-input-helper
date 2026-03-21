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
  - `Audio`: audio capture protocol
  - `Speech`: provider abstraction placeholder
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
- buffering and handoff to the speech layer

Dependency rule:

- may publish captured audio artifacts
- must not own provider prompts or insertion logic

### SpeechProvider

Responsibility:

- convert audio and context into a provider request
- normalize provider output into app-level result objects

Dependency rule:

- may depend on user key storage
- must not talk directly to the UI layer

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

### LocalStore

Responsibility:

- define local paths for history, diagnostics, and configuration
- own migration-safe storage layout

### Settings

Responsibility:

- user provider keys
- hotkey configuration
- preset and storage preferences

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
- temporary raw audio artifacts beyond the active session

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

- no real global hotkey registration yet (current build uses a local simulation path)
- no live microphone capture yet
- no provider networking yet
- no insertion bridge yet
- no permission prompts yet

## Open questions

- Which hotkey pair gives the best balance of reach and conflict avoidance?
- Should selection rewrite rely on Accessibility first, pasteboard fallback
  second, or the reverse?
- Where should provider keys live: Keychain only, or Keychain plus local
  metadata for multi-provider configs?

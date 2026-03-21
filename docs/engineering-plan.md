# Engineering Plan

## Confirmed scope

The initial product scope is intentionally narrow and product-shaped:

- native macOS helper app with a menu bar footprint
- global hotkey to start or finish a voice session
- global hotkey to cancel the current session
- microphone capture and cloud speech/model provider integration
- user-managed provider keys entered in the app UI
- local-first storage for history, settings, and diagnostics
- direct dictation lane into the focused app
- selection rewrite lane for highlighted text
- context-aware style presets based on frontmost app category

## Not in scope for now

The following ideas are explicitly deferred so v1 stays shippable:

- `InputMethodKit` input method integration
- fully offline ASR or local LLM inference
- iPhone or iPad companion apps
- cross-device sync
- complex multi-user collaboration features
- plugin marketplaces or user scripting
- broad automation surfaces before the core session loop is stable

## Phase plan

### Phase 0: Foundation

Goal:

- establish the standalone repository
- scaffold the native helper app
- define architecture, principles, and delivery rhythm

Done criteria:

- GitHub private repo exists and is connected
- the app builds locally
- product, architecture, milestone, and ADR docs exist

### Phase 1: Interaction spine

Goal:

- make the app feel like a real system tool

Scope:

- global wake and cancel shortcuts
- permissions center for microphone and accessibility
- low-noise status feedback
- session-state transitions wired to the new controls

Done criteria:

- a session can be started and cancelled with global shortcuts
- the app explains missing permissions clearly
- state changes remain visible without stealing focus

### Phase 2: Dictation path

Goal:

- turn speech into inserted text through a provider abstraction

Scope:

- audio capture
- provider layer for user-supplied cloud APIs
- key storage strategy
- insertion pipeline into the focused app
- local history for completed sessions

Done criteria:

- a spoken session can round-trip into a target app
- provider failures surface clear guidance
- history and settings remain local

### Phase 3: Selection rewrite

Goal:

- make selected-text rewrite feel first-class instead of bolted on

Scope:

- current selection detection
- rewrite prompt shaping
- replace-in-place pipeline
- guardrails for cancel and error paths

Done criteria:

- a highlighted text block can be rewritten in place
- cancel never mutates target-app content
- unsupported apps fail safely

### Phase 4: Scene tuning and polish

Goal:

- increase first-pass quality without adding chat-heavy UI

Scope:

- frontmost-app heuristics
- style presets and keyboard cycling
- searchable local history
- diagnostics and latency tracing

Done criteria:

- preset selection feels useful in at least three app categories
- users can override the preset quickly
- latency and failure data are visible locally

### Phase 5: Beta hardening

Goal:

- prepare the product for external testers

Scope:

- app signing and distribution path
- crash and diagnostics quality
- migration story for local data
- stronger manual smoke coverage across target apps

Done criteria:

- signed beta build can be installed cleanly
- diagnostics are enough to debug common failures
- upgrade path does not corrupt local history

## Risk list

- Accessibility APIs behave differently across target apps and may limit
  reliable selection rewrite.
- Global shortcut collisions can make the summon flow feel flaky.
- Cloud provider latency can erase the product's interaction advantage.
- Text insertion paths can break when apps reject pasteboard or automation
  techniques.
- Key handling must avoid leaking secrets into logs or plain-text history.
- Microphone and automation permissions can fail in confusing ways for users.

## Commit strategy

- Make one coherent change per commit.
- Keep product docs and implementation changes separate when possible.
- Prefer commit subjects that explain intent, such as `feat`, `docs`, `fix`,
  or `chore`.
- Do not batch unrelated refactors into feature commits.
- Keep the local build green at each checkpoint that changes runnable code.

## Testing and verification strategy

### Always-on checks

- command-line build with `xcodebuild`
- manual smoke pass on the menu bar app after UI or lifecycle changes
- document updates in the same round as any architecture shift

### Near-term automated coverage

- session-state unit tests
- provider contract tests for request and response shaping
- storage tests for local persistence and migration-safe paths

### Manual system checks

- launch and quit behavior as a helper app
- global hotkey conflict behavior
- permission prompts and denied-permission guidance
- insertion behavior in TextEdit, Notes, and at least one chat app

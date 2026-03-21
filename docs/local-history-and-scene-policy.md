# Local History and Scene Policy (Prompt 9)

## Scope delivered in this phase

- session history is persisted locally by default
- history can be viewed in-app and deleted entry-by-entry or fully cleared
- frontmost app detection exposes:
  - app name
  - bundle id
- app-level strategy can be configured in settings

## Local storage structure

Base directory:

- `~/Library/Application Support/PulseType/`

History file:

- `History/session-history-v1.json`

App policy store:

- `UserDefaults` key: `scene.policy.v1`

History record fields (`SessionHistoryEntry`):

- `timestamp`
- `mode` (`dictation` or `selectionRewrite`)
- `appName`
- `bundleID`
- `inputText`
- `outputText` (optional)
- `instructionText` (optional)
- provider metadata:
  - `transcriptionProvider`, `transcriptionModel`
  - `rewriteProvider`, `rewriteModel`
- outcome status: `success`, `failed`, `cancelled`
- `errorMessage` (optional)

Retention behavior:

- newest-first append
- capped in memory/file (`maxEntries`, default `3000`)
- individual delete and full clear available from settings

## Privacy boundary

Local-first defaults in current implementation:

- session history stays on device
- scene policy stays on device
- diagnostics and temporary audio files stay on device
- API keys are stored in macOS Keychain (not plain text files)

Remote-only operations:

- transcription and rewrite model calls to user-configured provider endpoints

No silent cloud sync exists in this phase.

## Scene awareness granularity (current)

Current scene signal is app-level:

- frontmost app name
- frontmost app bundle id

Not included yet:

- page content semantics
- deep per-window workflow understanding
- per-field intent inference

This keeps behavior explainable and reduces incorrect assumptions.

## Per-app policy model

Each app policy stores:

- `outputBias`: `neutral | formal | casual | structured`
- `preferSelectionRewrite`: `true | false`

Runtime effects:

- lane resolution can prefer selection rewrite when text selection exists
- rewrite intent parser can map generic polish commands using scene output bias
  - example: if bias is `structured`, generic polish commands route to structure action

## Future extension path

Planned evolution while keeping local-first control:

1. add policy test mode and quick preview before save
2. add app groups and inheritance (chat, docs, mail, notes)
3. optionally add opt-in local analytics for policy suggestions
4. add history filters/search with no server dependency

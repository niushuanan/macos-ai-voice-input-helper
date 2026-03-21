# PulseType

PulseType is a keyboard-first macOS helper app for AI voice input.
It is intentionally not an `InputMethodKit` input method.

Current repository goal: deliver a stable **trialable v0/v1** build with clear setup, clear limits, and local-first behavior.

## Why this project exists

Most dictation tools feel like either a bare microphone button or a full
keyboard replacement. PulseType takes a different path:

- stay outside the text system as a helper app
- make keyboard invocation and cancellation the main interaction
- treat direct dictation and selection rewrite as two first-class lanes
- tune output by context without forcing users into a chat window

## What works now

Core product loop:

- Global shortcuts: wake, stop, cancel
- Local audio recording + cloud transcription
- Dictation writeback into focused app
- Selection rewrite (`translate`, `polish`, `condense`, `structure`)
- Provider role split (transcription provider and rewrite provider)
- API key input in settings, stored in Keychain
- Local history with delete operations and app/mode/status filters
- App-aware policy (`output bias` + rewrite-lane preference)
- Permission center for microphone and accessibility
- Status feedback in menu bar, command deck, and HUD pulse

Engineering baseline:

- Unit tests for state machine, intent parsing, endpoint resolution, provider adapters
- GitHub Actions CI running macOS build and test

## Selected innovation tracks

- `Dual-lane invocation`: one summon action, then branch into direct dictation
  or selection rewrite without mode hunting
- `Scene-tuned style presets`: adapt tone and rewrite defaults from the
  frontmost app category, with keyboard cycling for fast override

These tracks are documented in
[docs/product-principles.md](docs/product-principles.md).

## Current limits (important)

- Compatibility is validated on a limited app set; broad editor coverage is not complete yet.
- AX direct insertion can still vary across target apps and app versions.
- No offline ASR or local LLM path in this stage.
- No signed/notarized distributable package in this stage.

See [docs/compatibility-matrix-v1.md](docs/compatibility-matrix-v1.md) for tested targets and known unstable scenarios.

## Quick start

Generate project:

```bash
xcodegen generate
```

Build:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project PulseType.xcodeproj \
  -scheme PulseType \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Test:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project PulseType.xcodeproj \
  -scheme PulseType \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Trial checklist

1. Configure provider profile and API key in settings.
2. Grant microphone permission.
3. Grant accessibility permission.
4. Try direct dictation in TextEdit.
5. Try selection rewrite with highlighted text.
6. Check history panel and filters.

## Key documents

- [docs/install.md](docs/install.md)
- [docs/usage.md](docs/usage.md)
- [docs/api-key-setup.md](docs/api-key-setup.md)
- [docs/product-principles.md](docs/product-principles.md)
- [docs/engineering-plan.md](docs/engineering-plan.md)
- [docs/architecture.md](docs/architecture.md)
- [docs/hotkeys-permissions.md](docs/hotkeys-permissions.md)
- [docs/audio-session.md](docs/audio-session.md)
- [docs/transcription-provider.md](docs/transcription-provider.md)
- [docs/text-output.md](docs/text-output.md)
- [docs/compatibility-matrix-v1.md](docs/compatibility-matrix-v1.md)
- [docs/local-history-and-scene-policy.md](docs/local-history-and-scene-policy.md)
- [docs/release-checklist.md](docs/release-checklist.md)
- [docs/v1-backlog.md](docs/v1-backlog.md)
- [docs/milestones.md](docs/milestones.md)
- [docs/adr/0001-helper-app-direction.md](docs/adr/0001-helper-app-direction.md)

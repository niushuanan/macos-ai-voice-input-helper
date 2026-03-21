# PulseType

PulseType is a keyboard-first macOS helper app for AI voice input.
It is intentionally not an `InputMethodKit` input method. The product target is
a menu bar and global-hotkey tool that can be summoned from anywhere, use
user-supplied cloud model keys, and keep history plus configuration on the
local machine by default.

## Why this project exists

Most dictation tools feel like either a bare microphone button or a full
keyboard replacement. PulseType takes a different path:

- stay outside the text system as a helper app
- make keyboard invocation and cancellation the main interaction
- treat direct dictation and selection rewrite as two first-class lanes
- tune output by context without forcing users into a chat window

## Current status

This repository now includes:

- a native macOS SwiftUI helper app scaffold built around `MenuBarExtra`
- a menu bar icon plus basic menu actions (wake, stop, cancel, settings, quit)
- a command deck window for interaction drill and diagnostics visibility
- a short non-blocking status HUD pulse on state changes
- native local audio recording into temporary `.m4a` clips with session-level cleanup
- live listening-level feedback in the menu bar and command deck
- OpenAI cloud transcription path from recorded audio to text result
- multi-provider profile center with Keychain-backed per-profile API keys
- split routing: one provider for transcription, another for rewrite
- OpenAI official and OpenAI-compatible endpoint support
- selection-aware rewrite lane with action parsing (`translate`, `polish`, `condense`, `structure`)
- focus-aware text writeback engine with explicit fallback labeling
- a session-state spine covering `idle`, `listening`, `transcribing`,
  `rewriting`, `inserting`, `cancelled`, and `error`
- architecture and engineering docs that define the path from phase 0 to beta

## Selected innovation tracks

- `Dual-lane invocation`: one summon action, then branch into direct dictation
  or selection rewrite without mode hunting
- `Scene-tuned style presets`: adapt tone and rewrite defaults from the
  frontmost app category, with keyboard cycling for fast override

These tracks are documented in
[docs/product-principles.md](docs/product-principles.md).

## Repository map

- `project.yml`: XcodeGen source of truth
- `PulseType.xcodeproj`: generated Xcode project
- `Sources/App`: app lifecycle and composition root
- `Sources/Core`: session, interaction, hotkey, provider, permissions, storage, diagnostics
- `Sources/UI`: menu bar menu, command deck, status HUD, and settings surfaces
- `docs/`: product, architecture, engineering plan, milestones, and ADRs

## Build

Generate the Xcode project:

```bash
xcodegen generate
```

Build from the command line:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project PulseType.xcodeproj \
  -scheme PulseType \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

If your shell already points to the full Xcode developer directory, the
`DEVELOPER_DIR` prefix is not necessary.

## Key documents

- [docs/product-principles.md](docs/product-principles.md)
- [docs/engineering-plan.md](docs/engineering-plan.md)
- [docs/architecture.md](docs/architecture.md)
- [docs/hotkeys-permissions.md](docs/hotkeys-permissions.md)
- [docs/audio-session.md](docs/audio-session.md)
- [docs/transcription-provider.md](docs/transcription-provider.md)
- [docs/text-output.md](docs/text-output.md)
- [docs/compatibility-matrix-v1.md](docs/compatibility-matrix-v1.md)
- [docs/milestones.md](docs/milestones.md)
- [docs/adr/0001-helper-app-direction.md](docs/adr/0001-helper-app-direction.md)

# Milestones

## M0: Repo and helper-app foundation

Outcome:

- standalone repo
- GitHub private remote
- native SwiftUI helper app scaffold
- baseline docs and ADR

Status:

- done

## M1: Hotkeys, cancel path, and permission center

Outcome:

- system-wide wake shortcut
- system-wide cancel shortcut
- visible state feedback
- first permission guidance flow

Proof points:

- start, cancel, and recover without touching the mouse
- app explains what is missing when permissions are blocked

## M2: Direct dictation loop

Outcome:

- audio capture
- provider request pipeline
- inserted text into the current app
- local session history

Proof points:

- speak in TextEdit and see text come back correctly
- failed provider calls do not lose the current session trace

## M3: Selection rewrite lane

Outcome:

- detect current selection
- rewrite selected text in place
- preserve a safe cancel path

Proof points:

- highlight text, invoke rewrite lane, and replace the selection
- unsupported targets do not corrupt the original text

## M4: Scene-tuned presets and history polish

Outcome:

- app-category style presets
- quick preset override
- better searchable history and diagnostics

Proof points:

- output feels better in at least Mail, Notes, and chat contexts
- users can understand why a preset was chosen

## M5: Beta readiness

Outcome:

- signing and distribution path
- better diagnostics
- repeatable smoke checklist

Proof points:

- beta build is installable by a test user
- major failure modes can be diagnosed from local traces

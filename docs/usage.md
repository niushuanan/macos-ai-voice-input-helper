# Usage Guide (Trial Build)

## Default shortcuts

- Wake / start: `Control + Option + Space`
- Stop / submit: `Control + Option + Return`
- Cancel session: `Control + Option + Escape`

## First-run checklist

1. Open PulseType settings from menu bar.
2. Configure provider profile and API key.
3. Allow microphone permission.
4. Allow accessibility permission for stable cross-app insertion/rewrite.

## Trial flows

### Flow 1: Direct dictation

1. Focus any text input field.
2. Press wake shortcut.
3. Speak.
4. Press stop shortcut.
5. PulseType transcribes and inserts text into focused app.

### Flow 2: Selection rewrite

1. Select text in the target app.
2. Press wake shortcut.
3. Speak command, for example:
   - "translate to Japanese"
   - "make it formal"
   - "condense this"
   - "organize as bullet points"
4. Press stop shortcut.
5. PulseType rewrites and replaces selected text.

## Status and diagnostics

- Menu bar icon:
  - listening level pips in recording phase
  - animated busy dots in transcribing/rewriting/inserting phases
- Command Deck:
  - phase, lane, provider/model, target app, writeback path
- History panel:
  - local session records with filters by mode/status/app

## Troubleshooting quick map

- "API key is missing":
  - open settings > Provider center, save key
- "Transcription request failed":
  - verify key, model, base URL, quota
- "No selected text detected":
  - select text first, then run rewrite lane
- "Accessibility permission is required":
  - enable PulseType in System Settings > Privacy & Security > Accessibility

# Text Output Design (Prompt 6)

## Goal

Move from "transcript visible" to "transcript written into current focused editor."

## Main path and fallback

Main path:

- `Accessibility` direct write path
- reads focused UI element from AX
- tries selected-range replacement by editing focused value
- updates cursor range when possible

Fallback path:

- explicit fallback, not hidden as main path
- temporary pasteboard write + synthetic `Command + V`
- original pasteboard content is restored after paste

## Output operation model

`TextOutputOperation`:

- `insertText`
- `replaceSelectedText`

`TextOutputResult`:

- target app name
- target bundle id
- path used (`accessibilitySelectionReplacement` or `pasteFallbackCommandV`)
- fallback flag
- operation type

## Error model

`TextOutputError` currently covers:

- empty text
- missing accessibility permission
- no focused element
- focused target not editable
- direct AX path failure
- pasteboard unavailable
- paste shortcut injection failure
- both paths failed

Each error is mapped to clear user-facing status text in session state.

## Focus context model

`FocusedAppContext` provides:

- app name
- bundle id
- focused role (if available)
- editable-target boolean
- strategy hint

## Logging

Writeback attempts and outcomes are logged to:

- `~/Library/Application Support/PulseType/Diagnostics/text-output.log`

Log lines include:

- app/bundle
- operation type
- direct path success/failure
- fallback success/failure

## Honest status

- Main route is AX direct insertion.
- In current local test environment, fallback path is the one consistently proven.
- AX direct path reliability depends on accessibility trust and target app AX behavior.

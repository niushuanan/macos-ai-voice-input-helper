# Compatibility Matrix v1 (Prompt 6)

Date: 2026-03-21  
Method: local manual probe (`scripts/writeback_probe.swift`) using the same writeback engine.

## Legend

- Direct: Accessibility direct path
- Fallback: pasteboard + `Command + V`
- Result:
  - ✅ verified
  - ⚠️ partial
  - ❌ failed

## Matrix

| App | Bundle ID | Scenario | Path used | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| TextEdit | `com.apple.TextEdit` | New document, cursor active | Fallback | ✅ | Probe reported success; focus editable flag returned false in this environment. |
| Notes | `com.apple.Notes` | New note, body editor active | Fallback | ✅ | Probe reported success; direct AX metadata unavailable in this environment. |
| Safari | `com.apple.Safari` | Address bar focused (`Cmd+L`) | Fallback | ✅ | Probe reported success for focused URL field insertion. |

## Known instability

- AX direct path currently depends heavily on accessibility trust state and target-app AX exposure.
- Focus editable detection can under-report (`false`) in some apps even when fallback paste still works.
- Rich editors and web editors may prefer fallback even when AX is available.

## Next validation targets

- VS Code editor
- Slack message box
- Xcode source editor
- Notion page editor

These targets are not marked verified yet.

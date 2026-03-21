# Hotkeys and Permissions

## Default hotkey strategy (v1 baseline)

The app uses a dedicated global shortcut for each core session action:

- Wake and start session: `Control + Option + Space`
- Stop listening and move to text stage: `Control + Option + Return`
- Cancel current session: `Control + Option + Escape`

Additional behavior:

- While in `listening`, pressing wake (`Control + Option + Space`) again also triggers stop.

Implementation notes:

- Global registration is provided by `KeyboardShortcuts` (Carbon-backed).
- Handlers route into `InteractionCoordinator` to keep a single state path.
- Cancel only affects the active session; app quit remains a separate menu item.

## Why this strategy

- Separate stop and cancel avoids accidental termination while speaking.
- Stable key combinations reduce behavior ambiguity across app states.
- The recorder UI in settings allows key customization without custom low-level code.

## Permission model

Current permission coverage:

- Microphone: required for starting voice sessions.
- Accessibility: required for selection rewrite and cross-app insertion path.
- Global hotkeys: no additional permission required under current approach.

Permission handling:

- `PermissionsCenter` performs runtime detection and request actions.
- Missing microphone permission blocks session start with explicit error feedback.
- Accessibility gaps are surfaced in settings and in menu guidance.

## Known system limits

- Global shortcut conflicts with system shortcuts can still happen depending on user setup.
- Accessibility behavior differs across third-party apps, especially for selected-text rewrite.
- In macOS sandbox contexts, some modifier combinations are restricted.
- Permission changes made in System Settings may require app focus switch before UI reflects the latest state.

## Prompt 3 polish candidates

### Candidate 1: Session-edge pulse HUD

- Value: clearer phase change visibility with very low interruption.
- Cost: low (already partly available).
- Risk: overuse can feel noisy.

### Candidate 2: Shortcut conflict advisor (Selected)

- Value: warns when wake, stop, and cancel become identical or ambiguous.
- Cost: low to medium.
- Risk: false safety if users create external conflicts in macOS later.

### Candidate 3: Permission-aware action strip

- Value: menu actions could dynamically explain blocked operations in place.
- Cost: medium.
- Risk: too much status text can make the menu heavy.

Selected for implementation in this round:

- Candidate 2, via settings-level conflict checks plus reset-to-default action.

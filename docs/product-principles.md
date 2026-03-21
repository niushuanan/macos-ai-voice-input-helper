# Product Principles

## Product posture

- PulseType is a `macOS helper app`, not an `InputMethodKit` input method.
- The keyboard is the primary control surface.
- The app must be callable from anywhere and cancellable immediately.
- Cloud model APIs come first; users bring their own provider keys.
- History, session transcripts, and configuration remain local by default.

## Innovation rule

Every product idea must clear both bars:

1. It should feel meaningfully different from a plain dictation button.
2. It should be realistic for a small v1 team to ship and verify.

The project will favor sharp interaction choices over broad feature sprawl.

## Candidate directions

| Direction | User value | Technical cost | Main risk | V1 fit | Decision |
| --- | --- | --- | --- | --- | --- |
| Dual-lane invocation | One mental model for both fresh dictation and selection rewrite. Users keep focus in the target app and do not need to dig through modes. | Medium. Requires global hotkeys, selection-aware branching, insertion control, and a stable state machine. | Accessibility edge cases can make selected-text rewrite unreliable across apps. | Yes | Selected |
| Post-capture intent strip | After speaking, users can tap a single key to apply an intent such as clean up, shorten, expand, or translate before the model call. This gives higher leverage than raw transcription. | Medium to high. Needs low-latency transient UI, intent routing, and careful timing so the extra step does not feel slow. | The extra decision point may feel like friction if response speed is not excellent. | Later | Parked |
| Scene-tuned style presets | Output starts closer to the right tone for Mail, chat, docs, notes, or code comments. Users spend less time cleaning up voice output. | Low to medium. Frontmost-app heuristics and a simple preset system are feasible early. | Wrong guesses can feel intrusive if the user cannot override them quickly. | Yes | Selected |

## Chosen innovation tracks

### 1. Dual-lane invocation

This is the main interaction signature for v1.

- Default lane: direct dictation into the focused app
- Alternate lane: rewrite the current selection in place
- The branch should happen with minimal mode switching
- Cancellation must always beat insertion

Why it matters:

- It makes the product feel more capable than plain dictation on day one.
- It aligns with the helper-app posture: the user stays in the current app.
- It gives a clean frame for later context detection and rewrite tools.

### 2. Scene-tuned style presets

This is the secondary differentiator for v1.

- Start with app-category heuristics instead of deep semantic context
- Expose a fast keyboard override so the system never feels locked
- Keep the initial preset set small and obvious

Why it matters:

- Voice input quality is often limited by tone mismatch, not just transcription
- A modest preset layer is cheap compared with fully autonomous context logic
- It gives the product a clear point of view without demanding heavy UI

## Non-negotiable interaction principles

- Summon and cancel actions must be easy to memorize.
- Status feedback must be visible but low interruption.
- The system must never silently replace text after a cancel path.
- Users should not be forced into a chat transcript view for basic tasks.
- Local data should remain inspectable and removable.

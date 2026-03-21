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

## Keyboard interaction candidates (Prompt 2)

### Candidate A: Hold-to-talk lane switch

- Wake: hold `Control + Option + Space`
- Stop: release key combo
- Cancel: tap `Control + Option + Escape`
- Lane split:
  - normal hold -> direct dictation
  - hold with `Option` and active selection -> selection rewrite
- HUD: optional, can be skipped
- Learning cost: low
- System conflict risk: medium
- Dev complexity: medium to high (key-down and key-up global tracking)
- Innovation impact: medium
- V1 fit: fair but not ideal

### Candidate B: Tap-tap dual-lane session (Selected)

- Wake: tap `Control + Option + Space`
- Stop: tap the same combo again
- Cancel: tap `Control + Option + Escape`
- Lane split:
  - wake tap by default -> direct dictation
  - wake tap with active text selection -> selection rewrite
- HUD: yes, short pulse status overlay (about 1 second)
- Learning cost: low to medium
- System conflict risk: low to medium
- Dev complexity: medium
- Innovation impact: high (clear, memorable rhythm)
- V1 fit: best

### Candidate C: Wake then command key lane

- Wake: tap `Control + Option + Space`, then pick lane key
- Stop: tap `Return`
- Cancel: tap `Escape`
- Lane split:
  - `D` for dictation
  - `R` for selection rewrite
- HUD: yes, command hint strip is required
- Learning cost: medium
- System conflict risk: low
- Dev complexity: medium
- Innovation impact: medium to high
- V1 fit: usable, but adds one extra decision step every session

## Selected keyboard skeleton for v1

We adopt Candidate B: `tap-tap dual-lane session`.

Reason:

- It keeps one primary summon combo, so users memorize fast.
- It preserves a strong cancel path with an independent shortcut.
- It gives a distinct interaction rhythm compared with plain dictation apps.
- It is easier to ship in v1 than hold-tracking or command-lane UIs.

## Prompt 4 listening-feedback candidates

| Candidate | User value | Implementation cost | Main risk | Decision |
| --- | --- | --- | --- | --- |
| Menu bar live level meter | Users can see that voice energy is being captured without opening any extra UI. The app feels active but stays low-noise. | Low. Reuse session listening level from `AudioCaptureService` and render tiny dynamic bars in the menu bar icon area. | Small icons can be hard to tune for readability on all menu bar themes. | Selected |
| Continuous floating listening chip | Gives strong confidence with a persistent on-screen feedback element while recording. | Medium. Needs a persistent non-activating panel lifecycle and careful multi-display positioning. | Easy to feel intrusive and visually noisy in daily usage. | Parked |

Selected in this round:

- `Menu bar live level meter` as the default listening feedback.
- Keep the existing short phase HUD for transition moments only.

## Prompt 5 trust-focused candidates

| Candidate | User value | Implementation cost | Main risk | Decision |
| --- | --- | --- | --- | --- |
| Provider transparency panel | Clearly shows active provider/model and request phase (`transcribing` in progress, latest transcript result) so users can trust what system is doing. | Low to medium. Mostly state + UI binding work. | If too verbose, it can clutter the command deck. | Selected |
| Post-failure guided recovery card | Shows tailored next actions per failure type (missing key, network, quota, bad model) with one-click shortcuts. | Medium. Needs richer error taxonomy + action routing. | Requires tighter coupling with settings/actions early. | Parked |

Selected implementation in this round:

- Provider/model visibility in the command deck.
- In-flight transcription status visibility.
- Latest transcript preview tied to provider and model metadata.

## Prompt 6 writeback innovation candidates

| Candidate | User value | Implementation cost | Main risk | Decision |
| --- | --- | --- | --- | --- |
| App-aware writeback transparency | Show target app, editable-target detection, strategy hint, and final path (direct vs fallback) so users know what the tool actually did. | Low to medium | Adds detail to panel; needs compact UI wording. | Selected |
| Short pre-insert preview gate | Pause 1-2 seconds for user confirmation before writing text. | Medium | Adds friction and can hurt fast dictation rhythm. | Parked |

Selected implementation:

- App-aware writeback transparency in command deck status card.
- Clear fallback labeling; fallback is never presented as main path.

## Prompt 7 rewrite interaction candidates

Goal in this phase:

- selected text -> wake shortcut -> speak command -> AI rewrite -> overwrite selection

### Candidate 1: Free command only

- How it works:
  - User says any natural-language command, such as "translate this to Japanese" or "make it concise."
  - System relies on intent parsing from raw speech every time.
- User understanding cost: low
- Development complexity: medium
- Product premium feel: medium
- V1 fit: good
- Main tradeoff:
  - Highest flexibility, but intent ambiguity can create unstable output.

### Candidate 2: Mode-first command vocabulary

- How it works:
  - User first says or taps a predefined action category (`translate`, `polish`, `condense`, `structure`), then optional detail.
  - System strongly constrains prompt templates.
- User understanding cost: medium
- Development complexity: low to medium
- Product premium feel: medium
- V1 fit: good
- Main tradeoff:
  - Predictable and robust, but feels rigid for advanced users.

### Candidate 3: Hybrid quick-actions + free command fallback (Selected)

- How it works:
  - System first maps spoken text into known actions when possible:
    - `translate`
    - `polish`
    - `condense`
    - `structure`
  - If mapping is unclear, system falls back to a custom rewrite instruction.
- User understanding cost: low to medium
- Development complexity: medium
- Product premium feel: high
- V1 fit: best
- Main tradeoff:
  - Requires clean parser + template boundaries, but keeps both power and reliability.

Selected in this round:

- Candidate 3 (`hybrid quick-actions + free command fallback`)
- Why:
  - It keeps a clear "product behavior" for frequent actions.
  - It still supports natural language for long-tail edits.
  - It can be implemented with deterministic templates in v1 without heavy prompt engineering.

### Supported selection actions in v1

- `Translate`: supports common target-language detection from command phrases.
- `Polish`: formal or casual tone shifts.
- `Condense`: shorten while preserving key meaning.
- `Structure`: reorganize into bullet-point form.
- `Custom`: when no known quick-action matches, apply user command directly.

## Non-negotiable interaction principles

- Summon and cancel actions must be easy to memorize.
- Status feedback must be visible but low interruption.
- The system must never silently replace text after a cancel path.
- Users should not be forced into a chat transcript view for basic tasks.
- Local data should remain inspectable and removable.

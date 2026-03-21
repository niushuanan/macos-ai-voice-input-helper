# ADR 0001: Helper App Direction

- Status: Accepted
- Date: 2026-03-21

## Context

The product target is a system-level AI voice input tool for macOS. It needs
to be callable from anywhere, stay keyboard-first, support cloud model APIs
with user-supplied keys, and keep user history on the local machine by
default.

The team had two broad paths:

1. build a true input method with `InputMethodKit`
2. build a helper app that cooperates with target apps through hotkeys,
   permissions, and insertion bridges

## Decision

PulseType will be built as a macOS helper app.

It will not start as an `InputMethodKit` input method.

## Why this decision fits the product

- A helper app matches the desired menu bar and summon-anywhere interaction.
- It keeps the product focused on voice session quality instead of the full
  complexity of custom text-system ownership.
- It is a better match for cloud-provider experimentation in the early stages.
- It lets the product move faster on dictation and selection rewrite loops.

## Consequences

Positive:

- simpler initial architecture
- faster path to a keyboard-first beta
- better freedom to shape session UI and local history

Tradeoffs:

- text insertion and selection rewrite will depend on Accessibility or
  automation-style bridges
- some target apps may behave inconsistently
- the product will not behave like a full custom keyboard in every field

## Follow-on implications

- global hotkey and cancel behavior become core architecture concerns
- permission guidance must be treated as a first-class feature
- insertion reliability needs real-world smoke testing across target apps

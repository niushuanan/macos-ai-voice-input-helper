# Pre-Release Checklist (v0/v1 Trial)

## Build and test gates

- [ ] `xcodegen generate` completed
- [ ] Debug build passes
- [ ] Release build passes (`CODE_SIGNING_ALLOWED=NO` for local verification)
- [ ] Unit tests pass
- [ ] GitHub CI passes on latest commit

## Functional smoke checks

- [ ] Wake / stop / cancel shortcuts work
- [ ] Microphone permission gate works
- [ ] Accessibility permission gate and guidance work
- [ ] Direct dictation inserts into at least one app
- [ ] Selection rewrite replaces selection in at least one app
- [ ] Fallback path status is visible when direct insertion fails

## Provider and error handling

- [ ] Missing key error is clear and actionable
- [ ] Invalid model or endpoint error is clear and actionable
- [ ] Network/provider failure messages include retry guidance
- [ ] Role split provider assignment works

## Local-first data checks

- [ ] History entries are saved locally
- [ ] History entry deletion works
- [ ] "Delete all history" works
- [ ] API keys remain in Keychain only
- [ ] Temporary audio files are cleaned by lifecycle and stale purge

## UX readiness

- [ ] Status feedback is understandable across session phases
- [ ] Settings information hierarchy is understandable
- [ ] History filters are usable for trial debugging
- [ ] Command Deck shows provider/model and writeback path

## Documentation readiness

- [ ] README reflects current capabilities and limits
- [ ] Installation steps validated on a clean machine
- [ ] Usage guide validated
- [ ] API key setup guide validated
- [ ] Known compatibility limits are documented

# API Key Setup

## Security baseline

- API keys are stored in macOS Keychain.
- Keys are not written into plain-text project config files.
- Session history stores provider names/models, not secret values.

## Configure provider profiles

In settings > Provider center:

1. Pick or create a profile.
2. Set provider type:
   - `OpenAI (Official)`
   - `OpenAI-Compatible`
3. Set model names:
   - transcription model (example: `whisper-1`)
   - rewrite model (example: `gpt-4o-mini`)
4. For compatible providers, set `Base URL`.
5. Paste API key and click `Save`.

## Role split

You can assign different profiles per role:

- Transcription provider
- Rewrite provider

This allows speed/quality/cost tuning by stage.

## Common setup mistakes

- Empty or short API key
- Wrong provider type for current endpoint
- Base URL includes unsupported scheme
- Invalid model name (whitespace or empty)
- Profile disabled while selected for a role

## Recommended first profile

- Provider type: `OpenAI (Official)`
- Base URL: fixed (`https://api.openai.com`)
- Transcription model: `whisper-1`
- Rewrite model: `gpt-4o-mini`

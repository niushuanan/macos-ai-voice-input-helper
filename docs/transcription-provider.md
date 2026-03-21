# Transcription Provider Design (Prompt 5)

## First provider choice

Selected first provider: `OpenAI` audio transcription API.

Why this provider first:

- Stable and widely used speech transcription endpoint for a first production baseline.
- Supports the audio format already produced by this app (`.m4a` AAC).
- Strong model compatibility path (`whisper-1` default, configurable model name in settings).
- Good fit for the current phase where users bring their own API key.

## Key storage strategy

Credential handling uses split storage:

- API key:
  - stored in macOS Keychain via `SecItemAdd` / `SecItemUpdate` / `SecItemCopyMatching`
  - service: `com.niushuanan.PulseType.transcription`
  - account: provider id (for example `openAI`)
  - never written to plain-text config files
- provider id and model name:
  - stored in `UserDefaults` as non-secret configuration metadata

This keeps sensitive values in system secure storage while preserving easy settings persistence.

## Provider extension points

The transcription layer is designed for future multi-provider expansion:

- `SpeechProviderID` enum:
  - adds new provider identities and provider-specific defaults
- `SpeechTranscriptionProvider` protocol:
  - each provider implements `transcribe(request:configuration:apiKey:)`
- `SpeechProviderRegistry`:
  - maps provider id to concrete provider implementation
- `ProviderSettingsStore`:
  - provider selection, model configuration, key lifecycle UI state
- `ProviderCredentialStore` protocol:
  - allows alternate secure stores if needed, while default stays Keychain

To add a new provider later:

1. add a new case in `SpeechProviderID`
2. implement `SpeechTranscriptionProvider`
3. register the provider in `SpeechProviderRegistry` setup
4. optionally add provider-specific validation rules

## Runtime request path

Current path from recording to transcript:

1. user starts recording with hotkey
2. user stops recording
3. app creates transcription request from recorded clip
4. provider credentials are loaded from Keychain
5. multipart audio upload is sent to provider
6. transcript is parsed and published in session state

## Error handling coverage

Current explicit handling includes:

- missing API key
- network failure
- provider error payloads (including HTTP status and message)
- unsupported audio format
- malformed provider response
- user cancellation during request

# Provider Platform Design (Prompt 8)

## Goal for this phase

Move from a single-provider path to a profile-based provider platform:

- user can bring their own API keys
- transcription and rewrite can route to different providers
- settings UI manages provider type, base URL, model, enable state, and key
- expansion path favors `OpenAI-compatible` coverage first

## Innovation candidates (Prompt 8)

| Candidate | User understanding cost | Build cost | Premium feel | V1 fit | Decision |
| --- | --- | --- | --- | --- | --- |
| Split routing by role (transcription vs rewrite) | Low | Medium | High | Excellent | Selected |
| Per-mode model pool with auto policy | Medium | Medium to high | High | Fair | Parked |
| Endpoint profile marketplace templates | Medium | High | Medium | Later | Parked |

Selected implementation:

- **Split routing by role**
  - each role can bind to a different provider profile
  - each profile can have its own model and endpoint
  - key is isolated per profile in Keychain

## Current provider matrix

| Provider type | Transcription | Rewrite generation | Base URL strategy | Key scope |
| --- | --- | --- | --- | --- |
| OpenAI (Official) | Yes | Yes | fixed to `https://api.openai.com` | per profile |
| OpenAI-Compatible | Yes | Yes | user-defined `base URL` | per profile |

Notes:

- both rows use one shared contract family, but endpoint policy is different
- OpenAI official mode gives stable defaults
- compatible mode gives broad vendor coverage with minimum custom code

## Native integration vs compatible integration

### Native (`OpenAI Official`)

- fixed endpoint
- fewer config mistakes
- best default path for first-time setup

### Compatible (`OpenAI-Compatible`)

- user can define custom endpoint
- enables fast integration with vendors that implement OpenAI-style APIs
- requires stronger form validation and clearer error messaging

## Settings UX in this phase

`Provider center` now includes:

- role assignment:
  - transcription provider profile
  - rewrite provider profile
- profile editor:
  - provider type
  - profile name
  - enable/disable
  - base URL (when compatible type is selected)
  - transcription model
  - rewrite model
  - API key save/delete

## Security and persistence strategy

- API keys:
  - Keychain storage per profile ID
  - never written into plain-text config files
- non-secret metadata:
  - provider profiles and role bindings in `UserDefaults`
  - includes type/name/base URL/model/enable state

## Runtime routing path

### Dictation lane

1. read transcription profile binding
2. validate profile enable state + model + endpoint
3. load profile API key from Keychain
4. resolve provider by `ProviderType`
5. run transcription request

### Selection rewrite lane

1. read rewrite profile binding
2. validate profile enable state + model + endpoint
3. load profile API key from Keychain
4. resolve rewrite provider by `ProviderType`
5. run text-generation rewrite request

## How to add a new provider type

1. Add a new case to `ProviderType`.
2. Define base URL policy and default models for that type.
3. Implement:
   - `SpeechTranscriptionProvider` support for the new type
   - `TextGenerationProvider` support for the new type
4. Register support in:
   - `SpeechProviderRegistry`
   - `RewriteProviderRegistry`
5. Add validation rules in `ProviderSettingsStore` if this type needs extra fields.
6. Confirm settings UI shows the type and can save valid profile configuration.

## Known limits in this phase

- provider-specific advanced params (temperature/top_p/prompt suffix) are not exposed yet
- no per-profile connectivity test button yet
- compatible endpoints can differ subtly in payload behavior; errors are surfaced but not auto-healed

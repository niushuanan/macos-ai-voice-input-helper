# PulseType

PulseType is a keyboard-first macOS helper app for AI voice input.
It is intentionally not an `InputMethodKit` input method.

Current repository goal: deliver a stable **trialable v0/v1** build with clear setup, clear limits, and local-first behavior.

## Why this project exists

Most dictation tools feel like either a bare microphone button or a full
keyboard replacement. PulseType takes a different path:

- stay outside the text system as a helper app
- make keyboard invocation and cancellation the main interaction
- treat direct dictation and selection rewrite as two first-class lanes
- tune output by context without forcing users into a chat window

## What works now

Core product loop:

- Global shortcuts: wake toggle + cancel
- Local audio recording + cloud transcription
- Dictation writeback into focused app
- Selection rewrite (`translate`, `polish`, `condense`, `structure`)
- Dual-role model config (`ASR` + `Text`) with one-click connectivity test
- API key input in settings, stored in Keychain
- Default cloud model pair: `Qwen3-ASR-Flash` (ASR) + `deepseek-chat` (text)
- Experimental local ASR option: `SenseVoice Small`
- Local history with delete operations and app/mode/status filters
- App-aware policy (`output bias` + rewrite-lane preference)
- Permission center for microphone and accessibility
- Status feedback in menu bar, desktop control center, and HUD pulse

Desktop information architecture:

- `首页`：会话控制、阶段状态、最近结果、今日统计
- `记忆`：时间线、筛选（全部/普通听写/选区改写/失败）、复制/删除/清空
- `技能`：口语过滤、个性提示词、按应用风格总开关与策略编辑
- `模型`：固定两卡（ASR/文本处理），含地址/模型/密钥/测试/最近测试结果
- `设置`：两键热键、权限中心、关于

Engineering baseline:

- Unit tests for state machine, intent parsing, endpoint resolution, provider adapters
- GitHub Actions CI running macOS build and test

## Selected innovation tracks

- `Dual-lane invocation`: one summon action, then branch into direct dictation
  or selection rewrite without mode hunting
- `Scene-tuned style presets`: adapt tone and rewrite defaults from the
  frontmost app category, with keyboard cycling for fast override

These tracks are documented in
[docs/product-principles.md](docs/product-principles.md).

## Current limits (important)

- Compatibility is validated on a limited app set; broad editor coverage is not complete yet.
- AX direct insertion can still vary across target apps and app versions.
- Local SenseVoice path is experimental and depends on local runtime/model files.
- No signed/notarized distributable package in this stage.

See [docs/compatibility-matrix-v1.md](docs/compatibility-matrix-v1.md) for tested targets and known unstable scenarios.

## Quick start

Generate project:

```bash
xcodegen generate
```

Install single local runtime first:

```bash
./scripts/install-local-app.sh
```

Then open `/Applications/PulseType.app` and enter the two API keys inside `模型` page.
If you really need a script path, `./scripts/setup-local-keys.sh` still exists as a compatibility helper.

Install local secret pre-check (optional but recommended):

```bash
./scripts/install-pre-commit-hook.sh
```

Build:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project PulseType.xcodeproj \
  -scheme PulseType \
  -configuration Debug \
  build
```

Test:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project PulseType.xcodeproj \
  -scheme PulseType \
  -configuration Debug \
  test
```

Runtime doctor:

```bash
./scripts/doctor-runtime.sh
```

One-time local cleanup when permission or old app-path state is stale:

```bash
./scripts/repair-local-runtime.sh
```

## Trial checklist

1. Open `模型` and verify defaults:
   - ASR: DashScope + `qwen3-asr-flash`
   - 文本: OpenAI-compatible + `https://api.deepseek.com` + `deepseek-chat`
2. Run both connectivity tests and confirm both succeed.
3. Open `设置` and grant microphone + accessibility permissions.
4. Go to `首页`, press wake key to start dictation, press again to stop.
5. Verify output text appears in target app.
6. Open `记忆` and verify history is visible and manageable.
7. Ensure app runtime path is `/Applications/PulseType.app` (single-version policy).

## Key documents

- [docs/install.md](docs/install.md)
- [docs/usage.md](docs/usage.md)
- [docs/api-key-setup.md](docs/api-key-setup.md)
- [docs/product-principles.md](docs/product-principles.md)
- [docs/engineering-plan.md](docs/engineering-plan.md)
- [docs/architecture.md](docs/architecture.md)
- [docs/hotkeys-permissions.md](docs/hotkeys-permissions.md)
- [docs/audio-session.md](docs/audio-session.md)
- [docs/transcription-provider.md](docs/transcription-provider.md)
- [docs/text-output.md](docs/text-output.md)
- [docs/compatibility-matrix-v1.md](docs/compatibility-matrix-v1.md)
- [docs/local-history-and-scene-policy.md](docs/local-history-and-scene-policy.md)
- [docs/release-checklist.md](docs/release-checklist.md)
- [docs/v1-backlog.md](docs/v1-backlog.md)
- [docs/milestones.md](docs/milestones.md)
- [docs/adr/0001-helper-app-direction.md](docs/adr/0001-helper-app-direction.md)

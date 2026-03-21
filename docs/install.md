# Installation Guide

## Target

- macOS 14 or later
- Apple Silicon or Intel Mac

## Prerequisites

1. Xcode installed at `/Applications/Xcode.app`
2. Xcode Command Line Tools
3. `xcodegen` installed

Install XcodeGen:

```bash
brew install xcodegen
```

## Build and install

Generate project:

```bash
xcodegen generate
```

Build Debug app:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project PulseType.xcodeproj \
  -scheme PulseType \
  -configuration Debug \
  build
```

Install to single runtime path (`/Applications/PulseType.app`):

```bash
./scripts/install-local-app.sh
```

This project now uses a single-version local policy:

- Daily use should launch from `/Applications/PulseType.app`
- New local updates should always overwrite that same path
- Avoid running from DerivedData for day-to-day usage

Runtime health check:

```bash
./scripts/doctor-runtime.sh
```

If permission or keychain state is stale due old app paths:

```bash
./scripts/repair-local-runtime.sh
```

## Run tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project PulseType.xcodeproj \
  -scheme PulseType \
  -configuration Debug \
  test
```

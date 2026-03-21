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

## Build and launch

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
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run from Xcode:

1. Open `PulseType.xcodeproj`
2. Select scheme `PulseType`
3. Run (`Cmd + R`)

After launch, PulseType appears in the macOS menu bar.

## Run tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project PulseType.xcodeproj \
  -scheme PulseType \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  test
```

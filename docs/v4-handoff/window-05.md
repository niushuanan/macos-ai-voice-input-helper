# Window 05 - 默认切到 V4 runtime

## 本窗目标

- `InteractionCoordinator` 默认走 V4 runtime。
- legacy runtime 只保留 debug 兜底入口。
- V4 事件继续映射回现有 `SessionStore / HUD / History`。
- `AppModel.bootstrap()` 负责创建并注入 V4 依赖，UI 层不直接持有 V4 runtime。

## 默认路由策略

- `selectionRewrite` 先经过 `MagicianLaneClassifier`。
- 如果 lane 是 `unsupportedMixedExternal`，仍然直接提示用户把命令拆开，现有拦截没有丢。
- 其余 lane 默认统一走 `V4MagicianRuntimeAdapter`。
- `V4RuntimeSwitchStore` 是唯一 runtime 选择入口：
  - debug 开关关闭：统一返回 `.v4`
  - debug 开关开启：`.nativeFast -> .legacyNative`，`.agent/.unsupportedMixedExternal -> .legacyAgent`
- `runtimeVersion` 现在固定按路由写入：
  - V4 = `4`
  - legacy native = `2`
  - legacy agent = `3`

## debug 开关配置方式

支持两种临时打开 legacy runtime 的方式，任意一种为真即可：

- `UserDefaults`

```bash
defaults write com.niushuanan.PulseType magician.debug.useLegacyRuntime -bool true
```

- `ENV`

```bash
export PULSETYPE_MAGICIAN_USE_LEGACY_RUNTIME=1
```

识别为真的 ENV 值包括：`1`、`true`、`yes`、`on`、`debug`、`legacy`。

关闭开关后，legacy 分支在 `InteractionCoordinator` 里不可达，日常主链只跑 V4。

## V4 事件、状态、历史

- `V4ToSessionStoreBridge` 已把 V4 事件映射回现有状态壳：
  - 进入运行或中间阶段 -> `SessionStore.markRewriting(...)`
  - 成功完成 -> `SessionStore.completeAction(...)`
  - 等用户补充、失败、取消 -> `SessionStore.fail(...)`
- `V4ToHistoryBridge` 现在会把以下字段持续写盘：
  - `magicianRuntimeVersion`
  - `magicianSessionID`
  - `magicianRunID`
  - `magicianGoalSummary`
  - `magicianStepSummaries`
  - `magicianEvidenceSummary`
  - `magicianExecutionTrace`
- V4 失败路径也会补齐失败 outcome 与 trace，不会静默丢历史。

## legacy 仍保留的最小范围

- `magicianNativeRuntime`
- `magicianAgentRuntime`

它们现在只剩一个用途：debug 打开时做临时兜底。`InteractionCoordinator` 里对应成员和执行入口都已标注 `legacy fallback only`，不再继续承接新功能。

## Window 06 可直接删的旧路径候选

- `InteractionCoordinator` 里 legacy runtime 路由分支本体
- `executeSelectionRewriteWithLegacyRuntime(...)`
- `magicianNativeRuntime` 的注入与默认 wiring
- `magicianAgentRuntime` 的注入与默认 wiring
- 仅为 legacy debug 准备的测试夹具兼容逻辑

前提是 Window 06 先确认 V4 默认链路在真实使用里稳定，且不再需要 legacy debug 兜底。

## 本窗新增测试

- `testSelectionRewriteDefaultsToV4Runtime`
- `testLegacyRuntimeEnabledByDebugFlag`
- `testLegacyRuntimeDisabledByDefault`
- `testV4FailureStillWritesHistoryTrace`
- `testV4SuccessWritesRuntimeVersion4AndStepSummary`

## 本窗命令与结果

### 定向测试

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PulseType.xcodeproj -scheme PulseType -destination "platform=macOS" test -only-testing:PulseTypeTests/InteractionCoordinatorV4RoutingTests
```

结果：

- 5 tests, 0 failures
- `InteractionCoordinatorV4RoutingTests` 全部通过

### fast suite

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
./scripts/test-magician-fast.sh
```

结果：

- `fast suite passed`

### 自动发布

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
scripts/auto-ship.sh --message "core: default magician runtime to v4" --files PulseType.xcodeproj/project.pbxproj Sources/App/AppModel.swift Sources/Core/Interaction/InteractionCoordinator.swift Sources/Core/V4/Adapters/V4MagicianRuntimeAdapter.swift Sources/Core/V4/Adapters/V4ToHistoryBridge.swift Sources/Core/V4/Adapters/V4ToSessionStoreBridge.swift Sources/Core/V4/Adapters/V4RuntimeSwitchStore.swift Tests/InteractionCoordinatorTests.swift Tests/InteractionCoordinatorV4RoutingTests.swift docs/v4/architecture/v4-master-architecture.md docs/v4-handoff/window-05.md
```

结果：

- 已完成 commit：`86f1f6a`
- 已 push 到：`origin/codex/magician-agent-v2`
- 已覆盖安装：`/Applications/PulseType.app`
- 脚本默认跳过 test phase；本窗测试已在脚本前单独跑完并通过

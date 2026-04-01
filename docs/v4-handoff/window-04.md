# Window 04 - V4 ToolKernel

## 本窗完成项

- 已实现 `V4ToolRegistry + V4ToolKernel + V4ToolHookPipeline + V4ToolBatchOrchestrator`。
- 已打通固定流水线：spec 检查 -> schema 检查 -> input 语义检查 -> 权限判定 -> pre-hooks -> tool 执行 -> post-hooks -> result/evidence 归一化 -> error 归一化。
- `V4AgentLoopEngine` 已改成可真实调用 `V4ToolKernel`，不再空转。
- `V4MagicianRuntimeAdapter` 已补好 Window 05 需要的注入入口。
- `MagicianToolExecutor` 仍保留，但已标记为 legacy，后续不再往旧入口加新 capability。

## 当前可用 tools

| Tool ID | 说明 | Scope | 并发 |
| --- | --- | --- | --- |
| `text.transform` | 按 instruction 处理文本，返回文本结果与 evidence | `text_processing` | 可并发 |
| `shell.command.run` | 在 allowlist 内执行命令，返回 exit code / stdout / stderr | 无 | 串行 |
| `apple.notes.create` | 在 Apple Notes 创建笔记，返回创建摘要与 evidence | `apple_native_apps` | 串行 |

## Scope 归属

- `text.transform` -> `MagicianPermissionScope.textProcessing` -> scope raw value: `text_processing`
- `shell.command.run` -> 不需要 scope
- `apple.notes.create` -> `MagicianPermissionScope.appleNativeApps` -> scope raw value: `apple_native_apps`

备注：

- `V4PermissionGate` 优先读 `MagicianFeatureToggleStore`。
- 如果没注入 `MagicianFeatureToggleStore`，则退化为读 `V4RunRequest.enabledFeatureIDs`。
- scope 未开启时返回结构化 deny，`V4ToolResult.status = denied`，并附带用户可读提示，不抛裸异常。

## Hook 设计摘要

- `V4ToolHookPipeline` 现在是通用流水线容器，支持三段：
- `preExecution`
- `postExecution`
- `postFailure`
- pre hook 可以改写 input，并追加 evidence lines。
- post hook 可以改写 output，并追加 evidence lines。
- failure hook 在 error 归一化后执行，可做日志、埋点、审计，不会改写本次结果。
- 当前 live 版本默认未挂具体 hooks，但接口和执行时序已经固定，Window 05 可以直接注入。

## Window 05 接线所需注入参数

`V4MagicianRuntimeAdapter.init(...)` 当前已支持：

- `loopEngine: (any V4AgentLoopRunning)?`
- `toolKernel: (any V4ToolKernelRunning)?`
- `providerSettingsStore: ProviderSettingsStore?`
- `featureToggleStore: MagicianFeatureToggleStore?`

默认行为：

- 如果外部直接注入 `loopEngine`，则沿用外部实现。
- 如果未注入 `loopEngine`，Adapter 会内部创建 `V4ToolKernel`。
- 内部创建 `V4ToolKernel` 时：
- `registry` 通过 `V4ToolRegistry.live(providerSettingsStore:)` 生成
- `permissionGate` 通过 `V4PermissionGate(featureToggleStore:)` 生成

Window 05 建议直接复用这几个注入点，不要再绕回旧 `MagicianToolExecutor`。

## 关键实现点

- `V4ToolRegistry`
- 统一管理 `spec` 与 `tool` 实例
- live 版本已注册首批 3 个 tools

- `V4ToolKernel`
- 固定执行顺序与 Claude Code 工具模型一致
- 统一做 schema、semantic validation、permission、hooks、result/error normalization

- `V4ToolBatchOrchestrator`
- 输入为 `[V4ToolUse]`
- `isConcurrencySafe == true` 的 tool 按连续批次并发执行
- 非并发安全 tool 串行执行
- 返回顺序与输入顺序一致
- 某个并发任务失败时，其他已完成任务结果仍保留

- `V4EvidenceNormalizer`
- 统一生成 `outputText`、`evidenceSummary`、`rawPayload`
- 在 success / failed / denied 三类结果里保持同一结构

- `V4ToolError`
- 已固定字段：`code`、`toolID`、`messageForUser`、`messageForDebug`、`recoverAction`

- `V4ToolResult`
- 已固定字段：`status`、`outputText`、`evidenceSummary`、`rawPayload`

## 本窗命令与结果

### 必读代码核对

```bash
cd /Users/zhuanghongkai/Desktop/src
rg -n "toolExecution|validate|permission|hooks|orchestration|batch|parallel|streaming" services/tools
sed -n '1,360p' services/tools/toolExecution.ts
sed -n '360,980p' services/tools/toolExecution.ts
sed -n '980,1760p' services/tools/toolExecution.ts
sed -n '1,260p' services/tools/toolOrchestration.ts
sed -n '1,360p' services/tools/toolHooks.ts
```

结果：

- 已核对 Claude Code 工具层执行模型、hooks 组织方式、并发批处理方式。
- V4 ToolKernel 的固定流水线、batch 规则与错误归一化逻辑，已按这个模型落地到 Swift 侧。

### 当前仓库代码核对

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
sed -n '1,360p' Sources/Core/Magician/MagicianToolExecutor.swift
rg -n "runProcess|runOsaScript|executeFeishuCLI|MagicianError" Sources/Core/Magician
sed -n '1,340p' Sources/Core/Magician/MagicianAgentModels.swift
sed -n '1,260p' Sources/Core/Magician/MagicianFeatureToggleStore.swift
```

结果：

- 已复用旧实现里的 `runProcess` 与 `runOsaScript` 作为底层 helper。
- 新入口统一切到 `V4ToolKernel`，未新增任何 capability 到旧 executor。

### 测试

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
xcodebuild -project PulseType.xcodeproj -scheme PulseType -destination "platform=macOS" test -only-testing:PulseTypeTests/V4ToolKernelTests
./scripts/test-magician-fast.sh
```

结果：

- `xcodebuild ... -only-testing:PulseTypeTests/V4ToolKernelTests` 已通过
- 7 tests, 0 failures
- `./scripts/test-magician-fast.sh` 已通过
- fast suite passed

## 本窗新增测试点

- `testUnknownToolID`
- `testSchemaValidationFail`
- `testPermissionDenied`
- `testConcurrencySafeBatchRunsInParallel`
- `testNonConcurrencySafeRunsSerial`
- `testToolErrorNormalized`
- `testResultOrderStable`

## Window 05 直接可用结论

- AgentLoop 已能真实调用 tool。
- 权限 deny / schema fail / 执行错误都已标准化。
- 批量编排已具备并发与顺序稳定能力。
- RuntimeAdapter 已有注入点，可直接接 `InteractionCoordinator`。

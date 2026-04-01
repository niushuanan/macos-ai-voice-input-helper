# Window 09 - Tool 全迁移 + 旧执行器退场

## 本窗目标

- 把魔术先生核心工具动作搬进 V4 ToolKernel
- 建立 manifest / 检索 / 最小元数据层
- 统一 retry / evidence / error 映射
- 让 `MagicianToolExecutor` 退出主执行链，只留桥接入口

## 本窗落地文件

- `Sources/Core/Magician/MagicianToolExecutor.swift`
- `Sources/Core/Magician/MagicianToolSupport.swift`
- `Sources/Core/Magician/MagicianFeatureModels.swift`
- `Sources/Core/V4/Adapters/V4MagicianRuntimeAdapter.swift`
- `Sources/Core/V4/ToolKernel/V4ToolKernel.swift`
- `Sources/Core/V4/ToolKernel/V4ToolRegistry.swift`
- `Sources/Core/V4/ToolKernel/V4ToolManifest.swift`
- `Sources/Core/V4/ToolKernel/V4ToolManifestIndex.swift`
- `Sources/Core/V4/ToolKernel/V4ToolRetryPolicy.swift`
- `Sources/Core/V4/ToolKernel/V4ToolErrorCatalog.swift`
- `Sources/Core/V4/ToolKernel/V4ToolEvidencePolicy.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4TextTransformTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4ShellCommandTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4AppleNotesTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4AppleScriptTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4CalendarCreateTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4MailComposeTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4MusicControlTool.swift`
- `Sources/Core/V4/ToolKernel/Tools/V4FeishuCLITool.swift`
- `PulseType.xcodeproj/project.pbxproj`
- `Tests/V4ToolExecutionScenarioTests.swift`
- `Tests/V4ToolManifestTests.swift`
- `docs/v4/architecture/claudecode-loop-tool-map.md`
- `docs/v4-handoff/window-09.md`

## 已迁移能力清单

本窗要求的 9 个动作已全部由 V4 ToolKernel 直承：

- `calendar.create_event` -> `apple.calendar.create`
- `notes.create_note` -> `apple.notes.create`
- `mail.compose_or_send` -> `apple.mail.compose`
- `music.control` -> `apple.music.control`
- `feishu.cli` -> `feishu.cli`
- `shell.command.run` -> `shell.command.run`
- `applescript.run` -> `applescript.run`
- `time_machine.create` -> `time_machine.create`
- `time_machine.remind` -> `time_machine.remind`

附带补齐：

- `text.transform` 继续留在 V4 ToolKernel，且改为内核内直接可跑，不再卡权限门

## Manifest / 策略层

### manifest 字段

`V4ToolManifest` 已统一包含：

- `toolID`
- `displayName`
- `domain`
- `requiredScope`
- `inputSchemaSummary`
- `isConcurrencySafe`
- `supportsRetry`
- `evidenceRequirement`

### 检索与列举

`V4ToolManifestIndex` 已提供：

- `search(keyword:)`
- `list(by:)`

### retry 规则

`V4ToolRetryPolicy` 已支持：

- 按 tool 配置最大 retry 次数
- 只在 `retryableCodes` 命中时继续 retry
- 在 `V4ToolKernel` 里统一判定 `isRetryable`

### evidence 规则

`V4ToolEvidencePolicy` 已支持：

- `summary` 级别 evidence 校验
- `structured` 级别 key 校验
- evidence 缺失直接失败，不伪造成功

关键动作当前要求：

- `apple.calendar.create`：`eventID/startAt/endAt`
- `apple.mail.compose`：`mailStatus`
- `feishu.cli`：`operation/evidenceID`

### error 统一

`V4ToolErrorCatalog` 已统一处理：

- unknown tool
- invalid JSON
- schema / semantic validation failure
- permission denied
- missing evidence
- legacy `MagicianError` -> `V4ToolError` 映射
- retry policy 后的 `isRetryable` 归一化

## 已删除旧分支清单

以下旧 executor 分支 / 私有实现已退出 `MagicianToolExecutor.swift` 主体：

- `MagicianEventAdapter`
- `MagicianNoteAdapter`
- `MagicianMusicAdapter`
- `executeFeishuCLI(intent:context:)`
- executor 文件内联的 `runProcess(...)`
- executor 文件内联的 `runOsaScript(...)`
- executor 文件内联的 `magicianEnsureApplicationReadyAppleScriptLines(...)`
- executor 文件内联的 `summarizedHistoryText(...)`
- executor 文件内联的 `magicianMusicSearchQueries(...)`
- executor 文件内联的 `firstQuotedSongTitle(...)`
- executor 文件内联的 `magicianMusicEvidenceMatchesQuery(...)`
- executor 里按 `createEvent/createNote/composeEmailDraft/controlMusic/feishuCLI` 直接分派的旧 `switch` 主分支

说明：

- 进程 / AppleScript / 历史文本等通用 helper 已搬到 `MagicianToolSupport.swift`
- 真实动作执行逻辑已搬到各个 `V4*Tool.swift`

## 仍保留的 legacy 薄层及原因

- `MagicianToolExecutor`
  原因：旧 `MagicianAgentRuntimeV3` 仍会走这个入口，本窗先把它压成参数桥接 + 结果回译层，避免一次动到太多 runtime 代码。

- `MagicianToolSupport.swift`
  原因：`Notes / Music / AppleScript` 这类能力还共用进程与脚本 helper；等 Window 10 把旧 runtime 彻底挪离后，再决定搬进 V4 shared 还是直接裁掉。

## 测试补齐

新增 / 扩展：

- `Tests/V4ToolExecutionScenarioTests.swift`
- `Tests/V4ToolManifestTests.swift`

已覆盖：

- `testTextTransformThenMailCompose`
- `testFeishuCommandWithEvidenceValidation`
- `testMusicControlStateTransition`
- `testCalendarCreateWithTimeParseFallback`
- `testRetryPolicyOnRetryableError`
- `testManifestSearchByKeywordAndScope`
- `testMissingEvidenceIsFailure`

另外修正：

- `V4AgentLoopEngineTests` 因 `text.transform` 被权限门拦住而偏离旧预期，本窗已改成内核内直接执行，并让全量测试重新通过

## Window 10 最终切换步骤清单

1. 把旧 runtime 的 tool 调用入口全部改成直接走 `V4AgentLoopEngine + V4ToolKernel`，不再经过 `MagicianToolExecutor`。
2. 清掉 `InteractionCoordinator` / `MagicianAgentRuntimeV3` 里残留的 legacy tool 路由分支。
3. 确认没有调用方后，删除 `MagicianToolExecutor` 与相关协议桥。
4. 复查 `MagicianToolSupport.swift` 是否还能被 V4 以外代码用到；若没有，继续删除或搬进 V4 shared。
5. 再跑一次全量测试与安装链，确认主链只有 V4 tool path 在工作。

## 本窗命令与结果

### 定向测试

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PulseType.xcodeproj -scheme PulseType -destination "platform=macOS" test -only-testing:PulseTypeTests/V4ToolExecutionScenarioTests -only-testing:PulseTypeTests/V4ToolManifestTests
```

结果：

- 8 tests, 0 failures
- `V4ToolExecutionScenarioTests` 全部通过
- `V4ToolManifestTests` 全部通过

### 主循环回归定位

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project PulseType.xcodeproj -scheme PulseType -destination "platform=macOS" test -only-testing:PulseTypeTests/V4AgentLoopEngineTests
```

结果：

- 6 tests, 0 failures
- 已验证 `text.transform` 不再触发多余权限阻断

### fast suite

```bash
cd "/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法"
./scripts/test-magician-fast.sh --full
```

结果：

- 362 tests, 0 failures
- `full suite passed`

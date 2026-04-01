# V4 最终状态

## 当前模块结构（文字图）

```text
AppModel.bootstrap
└── InteractionCoordinator
    ├── V4MagicianRuntimeAdapter
    │   ├── AgentLoop
    │   ├── PromptStack
    │   ├── ModelSlots
    │   ├── ToolKernel
    │   ├── Memory
    │   └── TimeMachine
    ├── V4ToSessionStoreBridge
    ├── V4ToHistoryBridge
    └── debug only
        ├── MagicianNativeRuntime
        ├── MagicianAgentRuntimeV3
        └── MagicianToolExecutor
```

## V4 与 legacy 边界

- 默认执行面：
  - 魔术先生默认只走 `V4MagicianRuntimeAdapter`
  - `InteractionCoordinator` 默认不主动初始化 legacy runtime
- debug 兜底面：
  - 只有显式打开 `PULSETYPE_MAGICIAN_USE_LEGACY_RUNTIME=1`，或写入 `magician.debug.useLegacyRuntime` 时，才允许走 legacy route
  - 即便开了 debug 开关，进入 runtime 之前就失败的预检场景，历史仍按 V4 默认主链记为 `magicianRuntimeVersion = 4`
- 历史与轨迹：
  - `V4ToHistoryBridge` 继续写 `magicianRuntimeVersion`
  - `V4ToHistoryBridge` 继续写 `magicianSessionID`
  - `V4ToHistoryBridge` 继续写 `magicianRunID`
  - `V4ToHistoryBridge` 继续写 `magicianGoalSummary`
  - `V4ToHistoryBridge` 继续写 `magicianStepSummaries`
  - `V4ToHistoryBridge` 继续写 `magicianEvidenceSummary`
  - `V4ToHistoryBridge` 继续写 `magicianExecutionTrace`

## 已删除文件清单

- 本窗无整文件删除。

说明：

- 当前没有找到“无引用且不影响 debug 兜底 / V4 共用 helper”的 legacy runtime 或 tool 文件，可以安全整文件移除。
- 本窗已经删除的旧代码项：
  - `InteractionCoordinator.outputSelectionRewriteV2`
  - `MagicianToolExecutor.swift` 内未再使用的 `MagicianMailExecuting`
  - `MagicianToolExecutor.init(...)` 内未再使用的 `mailAdapter` 参数

## 仍保留 legacy 清单与原因

- `Sources/Core/Magician/MagicianAgentModels.swift`
  - 仍承载 `MagicianNativeRuntime` 与 `MagicianAgentRuntimeV3`
  - 现在只给 debug 显式兜底和现有 legacy tests 使用
- `Sources/Core/Magician/MagicianToolExecutor.swift`
  - 仍是 legacy runtime 到 `V4ToolKernel` 的桥接层
  - 默认主链已经不再依赖它
- `Sources/Core/Magician/MagicianToolSupport.swift`
  - `V4AppleNotesTool`、`V4MusicControlTool`、`V4ShellCommandTool`、`V4AppleScriptTool` 还共用里面的进程 / AppleScript / music helper
- `Sources/Core/History/LocalHistoryStore.swift`
  - UI 历史页、V4 memory bridge、time machine 仍以它作为兼容落盘底座

## 下一阶段路线图

### Phase 1

- 把 legacy debug runtime 抽成更薄的 debug-only 组装层
- 目标是让默认 App 启动路径完全不接触 `Magician*Runtime` 构造细节

### Phase 2

- 推进 V4 history / memory / time machine 的统一存储
- 逐步减少 `LocalHistoryStore` 作为主 schema 的职责，只保留兼容读取

### Phase 3

- 继续把 `InteractionCoordinator` 压成纯入口桥
- 让 V4 事件、历史、trace 拼装全部内聚到 V4 目录，不再让 Interaction 层继续长业务代码

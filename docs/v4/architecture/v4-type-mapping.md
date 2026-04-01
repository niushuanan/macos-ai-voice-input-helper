# V4 类型映射

原则：

- V4 只保留跨模块可编排的 contract，不复制旧 `Magician*` runtime 细节。
- 旧 store、历史库、模型配置先保留，先经 bridge 接入。
- 等 `AgentLoop + ToolKernel + Memory + TimeMachine` 跑稳，再逐窗移走旧主链。

## 映射表

| 旧类型 | 新类型 | 迁移动作 |
| --- | --- | --- |
| `MagicianAgentRequest` | `V4RunRequest` | 重写。保留 `traceID`、lane 语义与上下文快照，但去掉旧 runtime 专用字段。 |
| `MagicianAgentRuntimeEvent` | `V4RuntimeEvent` | 重写。改成统一可序列化事件，供 `SessionStore`、history、time machine 共用。 |
| `MagicianAgentRunOutcome` | `V4RunOutcome` | 重写。保留 `goalSummary`、steps、evidence 的结果面，去掉旧 runtime 的展示耦合。 |
| `MagicianExecutionResult` | `V4ToolResult` / `V4ToolError` | 重写。把单步执行结果拆成工具结果与错误模型，不再混放在 `MagicianIntent.swift`。 |
| `SessionHistoryEntry` | `V4MemoryEntry` / `V4TimeItem` / `V4ToHistoryBridge` | 复用 + 重写。旧 JSON 历史库先保留，Window 05/06 经 bridge 写入，Window 09 再拆成记忆与时间线模型。 |
| `InputLane` | `V4Lane` | 重写。值保持三条 lane 一致，但新类型只服务 V4 内核。 |
| `ProviderSettingsStore` 的 `asrConfig / textConfig / cliTextConfig` | `V4ModelEndpoint` / `V4ModelCredentialRef` | 复用 + 重写。配置源继续保留，解析与选模逻辑迁到 V4。 |
| `SkillRuleStore` / `AppScenePolicyStore` / `ASRDictionaryStore` 的 prompt 输入 | `V4PromptContext` / `V4PromptLayer` / `V4PromptEnvelope` | 复用 + 重写。数据源保留，拼装层统一搬进 V4 Prompt。 |
| `MagicianAgentCheckpoint` | `V4TimeItem` | 重写。旧 checkpoint 文件先保留，后续改成时光机统一时间项。 |

## 当前判断

1. `MagicianAgentRequest`、`MagicianAgentRuntimeEvent`、`MagicianAgentRunOutcome` 都不适合直接改名沿用，原因是它们绑定了旧 runtime 状态机与展示文案。
2. `SessionHistoryEntry` 目前仍是最稳定的落盘层，所以本窗只建 `V4ToHistoryBridge`，不碰现有 JSON schema。
3. `MagicianExecutionResult` 的职责太混，V4 里已经切成 `V4StepRecord + V4ToolResult + V4ToolError` 这三层。

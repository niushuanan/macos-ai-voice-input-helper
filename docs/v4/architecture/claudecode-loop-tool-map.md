# claudecode 主循环与工具层对位图

目标：把 `/Users/zhuanghongkai/Desktop/src` 里的 `AgentLoop + ToolKernel + memory retrieval + prompt layering + model slots`，对到 PulseType 当前实现，明确哪些保留、哪些重写、哪些删掉。

## claudecode 主循环关键状态

| claudecode 关键状态 | 真实文件路径 | 作用 | PulseType 对位模块 | 迁移动作 |
| --- | --- | --- | --- | --- |
| `messages` | `/Users/zhuanghongkai/Desktop/src/query.ts` | 一轮又一轮累计上下文，驱动后续 `tool_use` 与下一轮模型请求 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Session/SessionStore.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/History/LocalHistoryStore.swift` | 保留“状态壳 + 历史库”这个方向；重写为 `V4TurnState`，不再由 `InteractionCoordinator` 手写多分支流转 |
| `toolUseContext` | `/Users/zhuanghongkai/Desktop/src/query.ts`<br>`/Users/zhuanghongkai/Desktop/src/Tool.ts` | 工具、权限、上下文、abort、query tracking 的统一容器 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` 当前注入的一串依赖<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` 里的 runtime context | 重写。V4 要把依赖捏成一个 `AgentLoopContext`，不再靠巨型 init 把所有东西塞进 Coordinator |
| `turnCount` / `maxTurns` | `/Users/zhuanghongkai/Desktop/src/query.ts` | 明确一轮工具后是否继续下一轮 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` 里的 `MagicianAgentRuntimeV3.run(...)` 循环与 post-step 判断 | 重写。当前没有统一 turn 预算概念，V4 要把它升成公共状态 |
| `pendingMemoryPrefetch` | `/Users/zhuanghongkai/Desktop/src/query.ts` | 在模型流式输出时并行预取相关记忆 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/History/LocalHistoryStore.swift` 当前只做历史落盘，没有检索层 | 新增。保留 `LocalHistoryStore`，另起 `Sources/Core/V4/Memory/*` 做 retrieval |
| `systemPrompt + userContext + systemContext` | `/Users/zhuanghongkai/Desktop/src/query.ts`<br>`/Users/zhuanghongkai/Desktop/src/utils/api.ts` | 真正发给模型前的 prompt 分层拼装 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Skills/SkillRuleStore.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Context/AppScenePolicyStore.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Speech/ASRDictionaryStore.swift` | 保留数据源；重写拼装层。旧逻辑散在 Coordinator、SkillRuleStore、MagicianAgentRuntimeV3 里，V4 必须集中到 `Prompt` 目录 |
| `currentModel` / runtime main loop model | `/Users/zhuanghongkai/Desktop/src/query.ts` | 按权限模式与上下文选择当前模型 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Speech/ProviderSettingsStore.swift` 的 `asrConfig` / `textConfig` / `cliTextConfig` | 保留三槽位配置；重写调度逻辑到 `Sources/Core/V4/Model/*` |

## claudecode 工具调用关键阶段

| claudecode 阶段 | 真实文件路径 | 当前行为 | PulseType 对位模块 | 迁移动作 |
| --- | --- | --- | --- | --- |
| 工具分组与并发批次 | `/Users/zhuanghongkai/Desktop/src/services/tools/toolOrchestration.ts` | `partitionToolCalls` 按并发安全性分批，读操作并发，写操作串行 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` 的 fast plan / step plan<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianToolExecutor.swift` | 重写。PulseType 当前没有通用并发批次层，所有动作都绑在旧 runtime 上 |
| schema parse 与 `validateInput` | `/Users/zhuanghongkai/Desktop/src/services/tools/toolExecution.ts` | 先 `safeParse`，再跑每个 tool 的业务校验 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianIntent.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` 的 `magicianValidateToolCommandGuards(...)`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianToolExecutor.swift` 各 Adapter 的手写判断 | 重写。V4 要把每个工具参数变成 typed schema，不再混用自然语言与手写 if/else |
| `PreToolUse` hooks | `/Users/zhuanghongkai/Desktop/src/services/tools/toolHooks.ts` | 工具真正执行前插入额外上下文、阻断、改写输入 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` 的权限检查与命令补救<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` 的前置校验 | 新增统一层。旧逻辑保留能力探测，但不再继续扩写在 Coordinator 里 |
| 权限决策 | `/Users/zhuanghongkai/Desktop/src/services/tools/toolHooks.ts`<br>`/Users/zhuanghongkai/Desktop/src/services/tools/toolExecution.ts` | hook、规则、`canUseTool` 三层共同决定 allow / ask / deny | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Permissions/PermissionsCenter.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianFeatureModels.swift` 的 capability probe<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianToolExecutor.swift` | 保留 OS 能力探测；重写成 `V4ToolPermission`，让每个工具都走统一判定 |
| 工具执行 | `/Users/zhuanghongkai/Desktop/src/services/tools/toolExecution.ts`<br>`/Users/zhuanghongkai/Desktop/src/services/tools/StreamingToolExecutor.ts` | 统一跑工具、发进度、记 telemetry、回传 `tool_result` | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianToolExecutor.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/TextOutput/TextOutputCoordinator.swift`<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` | 重写。V4 要让 ToolKernel 直接产出结构化 result，再由 AgentLoop 决定下一轮 |
| `PostToolUse` hooks | `/Users/zhuanghongkai/Desktop/src/services/tools/toolHooks.ts` | 执行后补上下文、改输出、阻断后续继续跑 | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` 的 `handleMagicianRuntimeEvent(_:)`、trace 拼接、history append | 重写。当前 trace/telemetry/handoff 都耦合在 Coordinator 里 |
| `tool_result` 回灌下一轮 | `/Users/zhuanghongkai/Desktop/src/query.ts` | 工具结果并回 `messages`，驱动下一轮 turn | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift` 的 post-step 决策<br>`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift` 的 `SessionHistoryEntry` 落盘 | 重写。V4 的下一轮决策必须由 AgentLoop 统一推进，不能分散在 runtime 和 Coordinator 两头 |

## PulseType 对位模块

1. UI 壳：`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/UI/SettingsView.swift`、`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/UI/ControlCenterState.swift`
2. 会话状态壳：`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Session/SessionStore.swift`
3. 旧主链：`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Interaction/InteractionCoordinator.swift`
4. 旧 Agent runtime：`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianAgentModels.swift`
5. 旧工具执行层：`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Magician/MagicianToolExecutor.swift`
6. 现有 Prompt 数据源：`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Skills/SkillRuleStore.swift`、`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Context/AppScenePolicyStore.swift`、`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Speech/ASRDictionaryStore.swift`
7. 现有 Model slots 数据源：`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/Speech/ProviderSettingsStore.swift`
8. 现有 Memory seed：`/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/History/LocalHistoryStore.swift`

## Window 09 ToolKernel 对位表

| 旧能力 / 产品动作 | V4 toolID | 主实现文件 | manifest 约束 | legacy 状态 |
| --- | --- | --- | --- | --- |
| 建日程 | `apple.calendar.create` | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/ToolKernel/Tools/V4CalendarCreateTool.swift` | `domain=calendar`；`scope=appleNativeApps`；单次 retry；结构化 evidence 必须带 `eventID/startAt/endAt` | `MagicianToolExecutor` 只做桥接，不再直接碰 `EventKit` |
| 写备忘录 | `apple.notes.create` | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/ToolKernel/Tools/V4AppleNotesTool.swift` | `domain=notes`；`scope=appleNativeApps`；单次 retry；结构化 evidence 必须带 `noteID` | 旧 Notes/Shortcuts 分支已搬离 executor 主体 |
| 写邮件 / 发邮件 | `apple.mail.compose` | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/ToolKernel/Tools/V4MailComposeTool.swift` | `domain=mail`；`scope=mail`；单次 retry；结构化 evidence 必须带 `mailStatus` | 旧 runtime 仍经桥接入口进入 V4 |
| 控制音乐 | `apple.music.control` | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/ToolKernel/Tools/V4MusicControlTool.swift` | `domain=music`；`scope=appleNativeApps`；单次 retry；必须回传 evidence summary | 旧 Music adapter 已退出主链 |
| 飞书 CLI | `feishu.cli` | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/ToolKernel/Tools/V4FeishuCLITool.swift` | `domain=feishu`；`scope=cli`；双 retry；结构化 evidence 必须带 `operation/evidenceID` | 旧 executor 内嵌分支已移除 |
| Shell 命令 | `shell.command.run` | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/ToolKernel/Tools/V4ShellCommandTool.swift` | `domain=shell`；`scope=cli`；不 retry；结构化 evidence 必须带 `command/exitCode` | 已由 ToolKernel 直跑 |
| AppleScript | `applescript.run` | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/ToolKernel/Tools/V4AppleScriptTool.swift` | `domain=automation`；`scope=appleNativeApps`；单次 retry；结构化 evidence 必须带 `stdout/exitCode` | 已由 ToolKernel 直跑 |
| 时光机记录 | `time_machine.create` | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/ToolKernel/Tools/V4TimeMachineCreateTool.swift` | `domain=time_machine`；不 retry；结构化 evidence 必须带 `itemID` | Window 08 已接进 V4 |
| 时光机提醒 | `time_machine.remind` | `/Users/zhuanghongkai/Desktop/颠覆性 AI 语音输入法/Sources/Core/V4/ToolKernel/Tools/V4TimeMachineRemindTool.swift` | `domain=time_machine`；不 retry；结构化 evidence 必须带 `itemID` | Window 08 已接进 V4 |

manifest / 检索入口：

1. `V4ToolManifest` 定义 `toolID / displayName / domain / requiredScope / inputSchemaSummary / isConcurrencySafe / supportsRetry / evidenceRequirement`。
2. `V4ToolManifestIndex` 提供 `search(keyword:)` 与 `list(by:)`。
3. `V4ToolRegistry` 现在同时暴露 tool spec、tool 实体、manifest 查询与 live manifest 装配。
4. `V4ToolKernel` 在执行期统一套用 `V4ToolRetryPolicy`、`V4ToolEvidencePolicy`、`V4ToolErrorCatalog`。

## 迁移动作总判断

1. 保留：`SessionStore`、`ProviderSettingsStore`、`SkillRuleStore`、`ASRDictionaryStore`、`LocalHistoryStore` 先保留为桥接层。
2. 重写：`InteractionCoordinator` 里的 post-ASR 主流程，`MagicianAgentRuntimeV3`/`MagicianNativeRuntime` 的 turn 推进，`MagicianToolExecutor` 的工具调度方式。
3. 删除：等 V4 `AgentLoop` 与 `ToolKernel` 跑通后，逐窗移走 `Magician*Runtime` 主链与旧的 `selectedRuntime` 分派。
